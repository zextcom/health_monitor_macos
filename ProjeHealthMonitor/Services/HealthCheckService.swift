import Foundation
import Network
import Security

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
    private let dailyStatsStore: DailyStatsStore
    private let notificationService: NotificationService
    private let maxConcurrentChecks: Int
    private var loopTask: Task<Void, Never>?
    private var lastCheckedAt: [UUID: Date] = [:]

    /// Certificates don't change minute to minute, so we refresh them on a slower cadence than
    /// the health check itself and carry the last known value forward between refreshes.
    private let certCheckInterval: TimeInterval = 24 * 60 * 60
    private let certExpiryWarningDays = 14
    private var lastCertCheckedAt: [UUID: Date] = [:]
    private var certExpiryCache: [UUID: Date?] = [:]
    private var certWarnedFor: Set<UUID> = []

    nonisolated static let defaultMaxConcurrentChecks = 4

    init(endpointStore: EndpointStore, historyStore: HealthHistoryStore, dailyStatsStore: DailyStatsStore,
         notificationService: NotificationService, maxConcurrentChecks: Int = HealthCheckService.defaultMaxConcurrentChecks) {
        self.endpointStore = endpointStore
        self.historyStore = historyStore
        self.dailyStatsStore = dailyStatsStore
        self.notificationService = notificationService
        self.maxConcurrentChecks = max(1, maxConcurrentChecks)
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
        let workItems = makeDueCheckWorkItems(now: now)
        guard !workItems.isEmpty else { return }

        let outcomes = await Self.runCheckWorkItems(workItems, maxConcurrentChecks: maxConcurrentChecks)
        for outcome in outcomes {
            applyCheckOutcome(outcome)
        }
    }

    private func makeDueCheckWorkItems(now: Date) -> [CheckWork] {
        let dueEndpoints = Self.dueEndpoints(
            endpoints: endpointStore.endpoints,
            lastCheckedAt: lastCheckedAt,
            now: now,
            globalCheckInterval: endpointStore.globalCheckInterval
        )

        return dueEndpoints.map { endpoint in
            let interval = endpoint.checkIntervalOverride ?? endpointStore.globalCheckInterval
            lastCheckedAt[endpoint.id] = now

            return CheckWork(
                endpoint: endpoint,
                previousWasHealthy: historyStore.lastResult(for: endpoint.id)?.isHealthy,
                secret: SecretStore.secret(for: endpoint.id.uuidString),
                requestTimeout: endpointStore.requestTimeout,
                intervalSeconds: interval,
                cachedCertificateExpiresAt: certExpiryCache[endpoint.id] ?? nil,
                certificateFetch: certificateFetch(for: endpoint, now: now),
                startedAt: now
            )
        }
    }

    private func certificateFetch(for endpoint: Endpoint, now: Date) -> CertificateFetch? {
        guard endpoint.url.scheme?.lowercased() == "https",
              let host = endpoint.url.host,
              lastCertCheckedAt[endpoint.id].map({ now.timeIntervalSince($0) >= certCheckInterval }) ?? true
        else { return nil }

        let port = UInt16(exactly: endpoint.url.port ?? 443) ?? 443
        return CertificateFetch(host: host, port: port, timeout: min(endpointStore.requestTimeout, 10))
    }

    private func applyCheckOutcome(_ outcome: CheckOutcome) {
        let endpoint = outcome.endpoint
        guard endpointStore.endpoints.contains(where: { $0.id == endpoint.id }) else { return }

        let result = outcome.result
        if outcome.didRefreshCertificate {
            lastCertCheckedAt[endpoint.id] = outcome.startedAt
            certExpiryCache[endpoint.id] = result.certificateExpiresAt
        }

        historyStore.record(result)
        dailyStatsStore.record(endpointId: endpoint.id, timestamp: result.timestamp, isHealthy: result.isHealthy,
                                intervalSeconds: outcome.intervalSeconds)

        let wasHealthy = outcome.previousWasHealthy
        if wasHealthy == true, !result.isHealthy {
            if endpointStore.notificationsEnabled {
                notificationService.notifyDown(endpointName: endpoint.name, reason: result.failureReason)
            }
        } else if wasHealthy == false, result.isHealthy {
            if endpointStore.notificationsEnabled, endpointStore.notifyOnRecovery {
                notificationService.notifyRecovered(endpointName: endpoint.name)
            }
        }

        let expiringSoon = Self.isExpiringSoon(result.certificateExpiresAt, thresholdDays: certExpiryWarningDays)
        if expiringSoon, !certWarnedFor.contains(endpoint.id) {
            certWarnedFor.insert(endpoint.id)
            if endpointStore.notificationsEnabled, let expiry = result.certificateExpiresAt {
                notificationService.notifyCertificateExpiringSoon(endpointName: endpoint.name,
                                                                    daysRemaining: Self.daysUntilExpiry(expiry))
            }
        } else if !expiringSoon {
            certWarnedFor.remove(endpoint.id)
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

    struct CertificateFetch: Sendable {
        let host: String
        let port: UInt16
        let timeout: TimeInterval
    }

    struct CheckWork: Sendable {
        let endpoint: Endpoint
        let previousWasHealthy: Bool?
        let secret: String?
        let requestTimeout: TimeInterval
        let intervalSeconds: TimeInterval
        let cachedCertificateExpiresAt: Date?
        let certificateFetch: CertificateFetch?
        let startedAt: Date
    }

    struct CheckOutcome: Sendable {
        let endpoint: Endpoint
        let previousWasHealthy: Bool?
        let result: HealthCheckResult
        let intervalSeconds: TimeInterval
        let didRefreshCertificate: Bool
        let startedAt: Date
    }

    nonisolated static func dueEndpoints(
        endpoints: [Endpoint],
        lastCheckedAt: [UUID: Date],
        now: Date,
        globalCheckInterval: TimeInterval
    ) -> [Endpoint] {
        endpoints.filter { endpoint in
            let interval = endpoint.checkIntervalOverride ?? globalCheckInterval
            guard let last = lastCheckedAt[endpoint.id] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    nonisolated static func runCheckWorkItems(_ workItems: [CheckWork], maxConcurrentChecks: Int) async -> [CheckOutcome] {
        let limit = max(1, maxConcurrentChecks)
        var outcomes: [CheckOutcome] = []
        outcomes.reserveCapacity(workItems.count)

        await withTaskGroup(of: CheckOutcome.self) { group in
            var iterator = workItems.makeIterator()

            for _ in 0..<min(limit, workItems.count) {
                guard let work = iterator.next() else { break }
                group.addTask {
                    await performCheckWork(work)
                }
            }

            while let outcome = await group.next() {
                outcomes.append(outcome)
                if let nextWork = iterator.next() {
                    group.addTask {
                        await performCheckWork(nextWork)
                    }
                }
            }
        }

        return outcomes
    }

    private nonisolated static func performCheckWork(_ work: CheckWork) async -> CheckOutcome {
        var result = await executeCheck(endpoint: work.endpoint, timeout: work.requestTimeout, secret: work.secret)
        let didRefreshCertificate = work.certificateFetch != nil

        if let certificateFetch = work.certificateFetch {
            result.certificateExpiresAt = await fetchCertificateExpiry(
                host: certificateFetch.host,
                port: certificateFetch.port,
                timeout: certificateFetch.timeout
            )
        } else {
            result.certificateExpiresAt = work.cachedCertificateExpiresAt
        }

        return CheckOutcome(
            endpoint: work.endpoint,
            previousWasHealthy: work.previousWasHealthy,
            result: result,
            intervalSeconds: work.intervalSeconds,
            didRefreshCertificate: didRefreshCertificate,
            startedAt: work.startedAt
        )
    }

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
        url: URL, timeout: TimeInterval, headers: [String: String] = [:], session: URLSession = .shared
    ) async -> Result<RawFetchResult, RawFetchError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

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

    /// `secret` is the bearer token / basic-auth password / custom header value for `endpoint.authType`,
    /// resolved by the caller (from `SecretStore` in production, from the in-progress form state
    /// during "Test Connection") — kept as a plain parameter rather than an internal Keychain lookup
    /// so this stays a pure, easily testable function.
    nonisolated static func executeCheck(endpoint: Endpoint, timeout: TimeInterval, secret: String? = nil, session: URLSession = .shared) async -> HealthCheckResult {
        if endpoint.checkType == .tcp {
            return await executeTCPCheck(endpoint: endpoint, timeout: timeout)
        }

        let headers = authHeaders(type: endpoint.authType, username: endpoint.authUsername, secret: secret, headerName: endpoint.authHeaderName)
        switch await performRequest(url: endpoint.url, timeout: timeout, headers: headers, session: session) {
        case .failure(let error):
            return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                      responseTimeMs: error.elapsedMs, statusCode: nil, failureReason: error.displayMessage)
        case .success(let raw):
            guard raw.statusCode == endpoint.expectedStatusCode else {
                return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                          responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode,
                                          failureReason: "Expected status \(endpoint.expectedStatusCode), got \(raw.statusCode)")
            }

            if !endpoint.jsonAssertions.isEmpty {
                guard let json = try? JSONSerialization.jsonObject(with: raw.data) else {
                    return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                              responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode, failureReason: "Could not parse JSON")
                }
                let (passed, reason) = evaluateAssertions(json: json, assertions: endpoint.jsonAssertions)
                guard passed else {
                    return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                              responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode, failureReason: reason)
                }
            }

            return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: true,
                                      responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode, failureReason: nil)
        }
    }

    /// `.tcp` endpoints store their target as `endpoint.url` in `tcp://host:port` form (see
    /// `Endpoint.checkType`) rather than an HTTP URL — no status code, JSON assertions, or auth apply.
    private nonisolated static func executeTCPCheck(endpoint: Endpoint, timeout: TimeInterval) async -> HealthCheckResult {
        guard let host = endpoint.url.host, let port = endpoint.url.port, let nwPort = UInt16(exactly: port) else {
            return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                      responseTimeMs: nil, statusCode: nil, failureReason: "Invalid TCP target — host and port required")
        }
        let result = await performTCPConnect(host: host, port: nwPort, timeout: timeout)
        return HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: result.success,
                                  responseTimeMs: result.elapsedMs, statusCode: nil,
                                  failureReason: result.success ? nil : (result.errorMessage ?? "Connection failed"))
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

    /// Trimmed comparison shared by `executeCheck` and the form's live preview. `.regex` never
    /// throws on a malformed pattern — it just evaluates as no match (`try?`).
    nonisolated static func evaluate(actualValue: String, expectedValue: String?, mode: MatchMode = .exact) -> Bool {
        let expected = (expectedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = actualValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .exact:
            return actual.lowercased() == expected.lowercased()
        case .contains:
            return actual.localizedCaseInsensitiveContains(expected)
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: expected, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(actual.startIndex..., in: actual)
            return regex.firstMatch(in: actual, options: [], range: range) != nil
        }
    }

    /// Evaluates all assertions against `json` with AND semantics — the first failing assertion
    /// (missing field or mismatched value) short-circuits with its reason, mirroring the single-
    /// assertion failure messages `executeCheck` produced before multi-assertion support.
    nonisolated static func evaluateAssertions(json: Any, assertions: [JSONAssertion]) -> (passed: Bool, failureReason: String?) {
        for assertion in assertions {
            guard let actual = extractValue(from: json, path: assertion.path) else {
                return (false, "Field \"\(assertion.path)\" not found")
            }
            guard evaluate(actualValue: actual, expectedValue: assertion.expectedValue, mode: assertion.matchMode) else {
                return (false, "\"\(assertion.path)\" = \(actual), expected \(assertion.expectedValue)")
            }
        }
        return (true, nil)
    }

    /// Builds the HTTP header(s) for `type` given the (already-resolved) `secret`. Returns an
    /// empty dictionary whenever there's nothing usable to send (no secret, or a `.customHeader`
    /// without a header name) rather than sending a malformed auth header.
    nonisolated static func authHeaders(type: AuthType, username: String?, secret: String?, headerName: String?) -> [String: String] {
        guard let secret, !secret.isEmpty else { return [:] }
        switch type {
        case .none:
            return [:]
        case .bearerToken:
            return ["Authorization": "Bearer \(secret)"]
        case .basicAuth:
            let credentials = "\(username ?? ""):\(secret)"
            let encoded = Data(credentials.utf8).base64EncodedString()
            return ["Authorization": "Basic \(encoded)"]
        case .customHeader:
            guard let headerName, !headerName.isEmpty else { return [:] }
            return [headerName: secret]
        }
    }

    /// Percentage of `results` that were healthy, or `nil` if there's no history yet.
    /// Reflects whatever history is currently retained (see `HealthHistoryStore.maxResultsPerEndpoint`),
    /// not a fixed calendar window — callers should pair this with the covered time span if that matters.
    nonisolated static func uptimePercentage(results: [HealthCheckResult]) -> Double? {
        guard !results.isEmpty else { return nil }
        let healthyCount = results.filter(\.isHealthy).count
        return Double(healthyCount) / Double(results.count) * 100
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

    // MARK: - TLS certificate expiry

    /// Resumes a `CheckedContinuation` at most once. Guards against the timeout timer and the
    /// connection's state handler both firing (they run on the same serial queue but ordering
    /// across the timer and network callbacks isn't guaranteed to be race-free by inspection alone).
    private final class CertFetchResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<Date?, Never>

        init(continuation: CheckedContinuation<Date?, Never>) {
            self.continuation = continuation
        }

        func resumeOnce(_ value: Date?) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    /// Opens a raw TLS connection (no HTTP request) to `host:port` and reads the leaf
    /// certificate's expiry date from the handshake. Returns `nil` on any failure or timeout.
    nonisolated static func fetchCertificateExpiry(host: String, port: UInt16 = 443, timeout: TimeInterval = 10) async -> Date? {
        await withCheckedContinuation { continuation in
            let resumer = CertFetchResumer(continuation: continuation)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                resumer.resumeOnce(nil)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
            let queue = DispatchQueue(label: "com.zext.healthmonitor.cert-fetch")

            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.resumeOnce(nil)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var expiry: Date?
                    if let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        let secMetadata = tlsMetadata.securityProtocolMetadata
                        sec_protocol_metadata_access_peer_certificate_chain(secMetadata) { certificate in
                            guard expiry == nil else { return } // leaf certificate is reported first
                            let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
                            expiry = notAfterDate(from: secCert)
                        }
                    }
                    resumer.resumeOnce(expiry)
                    connection.cancel()
                case .failed, .cancelled:
                    resumer.resumeOnce(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private nonisolated static func notAfterDate(from certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let notAfterDict = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let numberValue = notAfterDict[kSecPropertyKeyValue] as? NSNumber
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: numberValue.doubleValue)
    }

    /// Whole days remaining until `expiryDate` (negative if already expired).
    nonisolated static func daysUntilExpiry(_ expiryDate: Date, from now: Date = Date()) -> Int {
        Int(expiryDate.timeIntervalSince(now) / 86400)
    }

    nonisolated static func isExpiringSoon(_ expiryDate: Date?, thresholdDays: Int, now: Date = Date()) -> Bool {
        guard let expiryDate else { return false }
        return daysUntilExpiry(expiryDate, from: now) <= thresholdDays
    }

    // MARK: - TCP connectivity

    struct TCPConnectResult {
        let success: Bool
        let elapsedMs: Int
        let errorMessage: String?
    }

    /// Same single-resume guard as `CertFetchResumer`, but tracks elapsed time and a plain
    /// success/failure outcome instead of a certificate expiry date.
    private final class TCPConnectResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let start = Date()
        private let continuation: CheckedContinuation<TCPConnectResult, Never>

        init(continuation: CheckedContinuation<TCPConnectResult, Never>) {
            self.continuation = continuation
        }

        func resumeOnce(success: Bool, errorMessage: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            continuation.resume(returning: TCPConnectResult(success: success, elapsedMs: elapsedMs, errorMessage: errorMessage))
        }
    }

    /// Opens a raw TCP connection to `host:port` (no TLS, no protocol handshake beyond the
    /// three-way handshake) to check basic reachability. Used for `.tcp` endpoints and the
    /// endpoint form's "Test Connection" flow.
    nonisolated static func performTCPConnect(host: String, port: UInt16, timeout: TimeInterval) async -> TCPConnectResult {
        await withCheckedContinuation { continuation in
            let resumer = TCPConnectResumer(continuation: continuation)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                resumer.resumeOnce(success: false, errorMessage: "Invalid port")
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.zext.healthmonitor.tcp-check")

            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.resumeOnce(success: false, errorMessage: "Timed out")
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resumeOnce(success: true, errorMessage: nil)
                    connection.cancel()
                case .failed(let error):
                    resumer.resumeOnce(success: false, errorMessage: error.localizedDescription)
                    connection.cancel()
                case .cancelled:
                    resumer.resumeOnce(success: false, errorMessage: "Cancelled")
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
