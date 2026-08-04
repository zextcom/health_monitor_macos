import Foundation

@MainActor
final class HealthCheckService: ObservableObject {
    enum OverallStatus {
        case unknown, healthy, down
    }

    @Published private(set) var overallStatus: OverallStatus = .unknown

    /// Granularity at which the loop wakes to check whether any endpoint is due; actual
    /// per-endpoint cadence is governed by `checkIntervalOverride` / `globalCheckInterval`.
    private let tickInterval: TimeInterval = 5

    private let endpointStore: EndpointStore
    private let historyStore: HealthHistoryStore
    private let notificationService: NotificationService
    private var loopTask: Task<Void, Never>?
    private var lastCheckedAt: [UUID: Date] = [:]

    init(endpointStore: EndpointStore, historyStore: HealthHistoryStore, notificationService: NotificationService) {
        self.endpointStore = endpointStore
        self.historyStore = historyStore
        self.notificationService = notificationService
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await checkDueEndpoints()
            updateOverallStatus()
            try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
        }
    }

    private func checkDueEndpoints() async {
        let now = Date()
        for endpoint in endpointStore.endpoints {
            let interval = endpoint.checkIntervalOverride ?? endpointStore.globalCheckInterval
            if let last = lastCheckedAt[endpoint.id], now.timeIntervalSince(last) < interval {
                continue
            }
            lastCheckedAt[endpoint.id] = now
            await performCheck(endpoint)
        }
    }

    private func performCheck(_ endpoint: Endpoint) async {
        let previousResult = historyStore.lastResult(for: endpoint.id)
        let result = await Self.executeCheck(endpoint: endpoint, timeout: endpointStore.requestTimeout)
        historyStore.record(result)

        let wasHealthy = previousResult?.isHealthy
        if wasHealthy == true, !result.isHealthy {
            if endpointStore.notificationsEnabled {
                notificationService.notifyDown(endpointName: endpoint.name, reason: result.failureReason)
            }
        } else if wasHealthy == false, result.isHealthy {
            if endpointStore.notificationsEnabled, endpointStore.notifyOnRecovery {
                notificationService.notifyRecovered(endpointName: endpoint.name)
            }
        }
    }

    private func updateOverallStatus() {
        guard !endpointStore.endpoints.isEmpty else {
            overallStatus = .unknown
            return
        }
        var sawResult = false
        var allHealthy = true
        for endpoint in endpointStore.endpoints {
            guard let last = historyStore.lastResult(for: endpoint.id) else { continue }
            sawResult = true
            if !last.isHealthy { allHealthy = false }
        }
        overallStatus = sawResult ? (allHealthy ? .healthy : .down) : .unknown
    }

    // MARK: - Raw networking (no actor-isolated state touched here beyond value types)

    struct RawFetchResult {
        let statusCode: Int
        let data: Data
        let elapsedMs: Int
    }

    enum RawFetchError: Error {
        case invalidResponse(elapsedMs: Int)
        case timedOut(elapsedMs: Int)
        case underlying(Error, elapsedMs: Int)

        var elapsedMs: Int {
            switch self {
            case .invalidResponse(let ms), .timedOut(let ms), .underlying(_, let ms):
                return ms
            }
        }

        var displayMessage: String {
            switch self {
            case .invalidResponse: return "Invalid response"
            case .timedOut: return "Timed out"
            case .underlying(let error, _): return error.localizedDescription
            }
        }
    }

    /// Performs a single GET request against `url`. Used both by `executeCheck` (which layers
    /// status-code/JSON-field evaluation on top) and by the endpoint form's "Test Connection"
    /// flow (which doesn't yet have a fully-configured `Endpoint` to evaluate against).
    nonisolated static func performRequest(
        url: URL, timeout: TimeInterval, session: URLSession = .shared
    ) async -> Result<RawFetchResult, RawFetchError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse(elapsedMs: elapsedMs))
            }
            return .success(RawFetchResult(statusCode: httpResponse.statusCode, data: data, elapsedMs: elapsedMs))
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if (error as? URLError)?.code == .timedOut {
                return .failure(.timedOut(elapsedMs: elapsedMs))
            }
            return .failure(.underlying(error, elapsedMs: elapsedMs))
        }
    }

    nonisolated static func executeCheck(endpoint: Endpoint, timeout: TimeInterval, session: URLSession = .shared) async -> HealthCheckResult {
        switch await performRequest(url: endpoint.url, timeout: timeout, session: session) {
        case .failure(let error):
            return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                      responseTimeMs: error.elapsedMs, statusCode: nil, failureReason: error.displayMessage)
        case .success(let raw):
            guard raw.statusCode == endpoint.expectedStatusCode else {
                return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                          responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode,
                                          failureReason: "Expected status \(endpoint.expectedStatusCode), got \(raw.statusCode)")
            }

            if let path = endpoint.jsonFieldPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                guard let json = try? JSONSerialization.jsonObject(with: raw.data) else {
                    return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                              responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode, failureReason: "Could not parse JSON")
                }
                guard let actualValue = extractValue(from: json, path: path) else {
                    return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                              responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode,
                                              failureReason: "Field \"\(path)\" not found")
                }
                guard evaluate(actualValue: actualValue, expectedValue: endpoint.expectedFieldValue) else {
                    return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                              responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode,
                                              failureReason: "\"\(path)\" = \(actualValue), expected \(endpoint.expectedFieldValue ?? "")")
                }
            }

            return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: true,
                                      responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode, failureReason: nil)
        }
    }

    // MARK: - JSON path resolution / discovery

    /// Resolves a dot-separated path (e.g. "data.status") against a JSONSerialization object graph,
    /// returning the leaf value stringified. Dictionary keys only — no array indices.
    nonisolated static func extractValue(from json: Any, path: String) -> String? {
        var current: Any = json
        for key in path.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        if let number = current as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let string = current as? String {
            return string
        }
        return nil
    }

    /// Trimmed, case-insensitive comparison shared by `executeCheck` and the form's live preview.
    nonisolated static func evaluate(actualValue: String, expectedValue: String?) -> Bool {
        let expected = (expectedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actual = actualValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return actual == expected
    }

    struct FlattenedJSONField: Identifiable {
        var id: String { path }
        let path: String
        let value: String
        let isSelectable: Bool
    }

    /// Flattens a JSONSerialization object graph into selectable dot-path/value pairs for the
    /// endpoint form's field picker. Dictionary keys only, consistent with `extractValue`'s
    /// traversal — array values are surfaced as non-selectable "[array]" rows rather than
    /// indexed into, since array indices aren't supported by `extractValue`.
    nonisolated static func flatten(json: Any, prefix: String = "") -> [FlattenedJSONField] {
        guard let dict = json as? [String: Any] else { return [] }
        var results: [FlattenedJSONField] = []
        for key in dict.keys.sorted() {
            let value = dict[key] as Any
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                results.append(contentsOf: flatten(json: nested, prefix: path))
            } else if value is [Any] {
                results.append(FlattenedJSONField(path: path, value: "[array]", isSelectable: false))
            } else if let number = value as? NSNumber {
                let str = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                results.append(FlattenedJSONField(path: path, value: str, isSelectable: true))
            } else if let string = value as? String {
                results.append(FlattenedJSONField(path: path, value: string, isSelectable: true))
            } else if value is NSNull {
                results.append(FlattenedJSONField(path: path, value: "null", isSelectable: false))
            }
        }
        return results
    }
}
