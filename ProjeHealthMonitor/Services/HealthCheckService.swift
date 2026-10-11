import Foundation
import Network
import Security

@MainActor
final class HealthCheckService: ObservableObject {
    /// Menu bar status: `down` beats `degraded` beats `healthy`.
    enum OverallStatus {
        case unknown, healthy, degraded, down
    }

    @Published private(set) var overallStatus: OverallStatus = .unknown

    /// Granularity at which the loop wakes to check whether any endpoint is due; actual
    /// per-endpoint cadence is governed by `checkIntervalOverride` / `globalCheckInterval`.
    private let tickInterval: TimeInterval = 5

    private let endpointStore: EndpointStore
    private let historyStore: HealthHistoryStore
    private let dailyStatsStore: DailyStatsStore
    private let notificationService: NotificationService
    private let versionStore: VersionStore
    private let healthDetailsStore: HealthDetailsStore
    private var loopTask: Task<Void, Never>?
    private var lastCheckedAt: [UUID: Date] = [:]

    /// Certificates don't change minute to minute, so we refresh them on a slower cadence than
    /// the health check itself and carry the last known value forward between refreshes.
    private let certCheckInterval: TimeInterval = 24 * 60 * 60
    private let certExpiryWarningDays = 14
    private var lastCertCheckedAt: [UUID: Date] = [:]
    private var certExpiryCache: [UUID: Date?] = [:]
    private var certWarnedFor: Set<UUID> = []

    /// Retained-deleted-endpoint records don't need to be swept every tick — hourly is plenty
    /// (mirrors the cert-cache cadence pattern above).
    private let retainedSweepInterval: TimeInterval = 60 * 60
    private var lastRetainedSweepAt: Date?

    /// Health checks performed per endpoint since its version check config last changed — drives
    /// the "every N checks" cadence (see `shouldRunVersionCheck`). In-memory only, so a relaunch
    /// runs the version check on the first health check again, which is what we want anyway.
    private var versionCheckCounters: [UUID: Int] = [:]
    private var versionCheckConfigsSeen: [UUID: VersionCheckConfig] = [:]

    init(endpointStore: EndpointStore, historyStore: HealthHistoryStore, dailyStatsStore: DailyStatsStore,
         notificationService: NotificationService, versionStore: VersionStore, healthDetailsStore: HealthDetailsStore) {
        self.endpointStore = endpointStore
        self.historyStore = historyStore
        self.dailyStatsStore = dailyStatsStore
        self.notificationService = notificationService
        self.versionStore = versionStore
        self.healthDetailsStore = healthDetailsStore
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
        pruneExpiredRetainedEndpoints()

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
        let secret = SecretStore.secret(for: endpoint.id.uuidString)
        let outcome = await Self.executeCheckDetailed(endpoint: endpoint, timeout: endpointStore.requestTimeout, secret: secret)
        var result = outcome.result
        result.certificateExpiresAt = await refreshedCertificateExpiry(for: endpoint)
        historyStore.record(result, retentionDays: endpointStore.historyRetentionDays)
        // Degraded counts as up for daily stats and uptime.
        dailyStatsStore.record(endpointId: endpoint.id, timestamp: result.timestamp, isHealthy: result.isHealthy,
                                intervalSeconds: endpoint.checkIntervalOverride ?? endpointStore.globalCheckInterval)

        if let transition = Self.healthTransition(previous: previousResult, current: result),
           Self.shouldNotify(transition, notificationsEnabled: endpointStore.notificationsEnabled,
                             notifyOnRecovery: endpointStore.notifyOnRecovery, isSnoozed: Self.isSnoozed(endpoint)) {
            switch transition {
            case .down(let reason):
                notificationService.notifyDown(endpointName: endpoint.name, reason: reason)
            case .recovered(let degradedReason):
                notificationService.notifyRecovered(endpointName: endpoint.name, degradedReason: degradedReason)
            case .degraded(let reason):
                notificationService.notifyDegraded(endpointName: endpoint.name, reason: reason)
            case .noLongerDegraded:
                notificationService.notifyNoLongerDegraded(endpointName: endpoint.name)
            }
        }

        if endpoint.healthStandard, let response = outcome.standardResponse {
            healthDetailsStore.record(response, for: endpoint.id, at: result.timestamp)
            recordAutoVersion(response, result: result, for: endpoint)
        }

        let expiringSoon = Self.isExpiringSoon(result.certificateExpiresAt, thresholdDays: certExpiryWarningDays)
        if expiringSoon, !certWarnedFor.contains(endpoint.id) {
            certWarnedFor.insert(endpoint.id)
            if endpointStore.notificationsEnabled, !Self.isSnoozed(endpoint), let expiry = result.certificateExpiresAt {
                notificationService.notifyCertificateExpiringSoon(endpointName: endpoint.name,
                                                                    daysRemaining: Self.daysUntilExpiry(expiry))
            }
        } else if !expiringSoon {
            certWarnedFor.remove(endpoint.id)
        }

        await performVersionCheckIfDue(endpoint)
    }

    /// Runs the endpoint's version check on every `everyNChecks`-th health check (including the
    /// first one after the config is set or changed) and dispatches any resulting notifications.
    /// Deliberately independent of the health result — never touches history/stats/overall status.
    private func performVersionCheckIfDue(_ endpoint: Endpoint) async {
        guard let config = endpoint.versionCheck, config.isEnabled else {
            versionCheckCounters.removeValue(forKey: endpoint.id)
            versionCheckConfigsSeen.removeValue(forKey: endpoint.id)
            return
        }
        if versionCheckConfigsSeen[endpoint.id] != config {
            versionCheckConfigsSeen[endpoint.id] = config
            versionCheckCounters[endpoint.id] = 0
        }
        let count = (versionCheckCounters[endpoint.id] ?? 0) + 1
        versionCheckCounters[endpoint.id] = count
        guard Self.shouldRunVersionCheck(checkCount: count, everyN: config.everyNChecks) else { return }

        let secret = SecretStore.secret(for: VersionCheckConfig.secretAccount(for: endpoint.id))
        let result = await Self.executeVersionCheck(config: config, timeout: endpointStore.requestTimeout, secret: secret)
        dispatchVersionEvents(versionStore.record(result, for: endpoint.id), for: endpoint)
    }

    /// Health-standard endpoints without an explicit, enabled version check track the version from
    /// the health response itself (no extra request) — see `HealthStandard.trackedVersion`.
    private func recordAutoVersion(_ response: HealthStandardResponse, result: HealthCheckResult, for endpoint: Endpoint) {
        guard Self.usesAutoVersion(endpoint),
              let value = HealthStandard.trackedVersion(version: response.version, releaseId: response.releaseId) else { return }
        let versionResult = VersionCheckResult(timestamp: result.timestamp, isSuccess: true, version: value, failureReason: nil,
                                               responseTimeMs: result.responseTimeMs, statusCode: result.statusCode)
        dispatchVersionEvents(versionStore.record(versionResult, for: endpoint.id), for: endpoint)
    }

    private func dispatchVersionEvents(_ events: [VersionCheckEvent], for endpoint: Endpoint) {
        let toNotify = Self.versionEventsToNotify(events, notificationsEnabled: endpointStore.notificationsEnabled,
                                                  notifyOnRecovery: endpointStore.notifyOnRecovery,
                                                  notifyOnVersionChange: endpointStore.notifyOnVersionChange,
                                                  isSnoozed: Self.isSnoozed(endpoint))
        for event in toNotify {
            switch event {
            case .changed(let from, let to):
                notificationService.notifyVersionChanged(endpointName: endpoint.name, from: from, to: to)
            case .failed(let reason):
                notificationService.notifyVersionCheckFailed(endpointName: endpoint.name, reason: reason)
            case .recovered:
                notificationService.notifyVersionCheckRecovered(endpointName: endpoint.name)
            }
        }
    }

    /// Returns the endpoint's cached certificate expiry, refreshing it first if it's stale or
    /// missing (only for HTTPS endpoints — everything else has no certificate).
    private func refreshedCertificateExpiry(for endpoint: Endpoint) async -> Date? {
        guard endpoint.url.scheme?.lowercased() == "https", let host = endpoint.url.host else { return nil }

        let now = Date()
        if let lastChecked = lastCertCheckedAt[endpoint.id], now.timeIntervalSince(lastChecked) < certCheckInterval {
            return certExpiryCache[endpoint.id] ?? nil
        }

        let port = UInt16(endpoint.url.port ?? 443)
        let expiry = await Self.fetchCertificateExpiry(host: host, port: port, timeout: min(endpointStore.requestTimeout, 10))
        lastCertCheckedAt[endpoint.id] = now
        certExpiryCache[endpoint.id] = expiry
        return expiry
    }

    /// Purges history/stats for retained-deleted endpoints past `EndpointStore.retainedDataExpiryDays`
    /// that were never reused — gated to run at most once per `retainedSweepInterval` since
    /// `endpointStore.retainedDeletedEndpoints` is typically tiny/empty. Not unit-tested at this
    /// instance-state level, consistent with the existing cert-cache above; `isRetainedRecordExpired`
    /// is the pure, tested piece of logic.
    private func pruneExpiredRetainedEndpoints() {
        let now = Date()
        if let last = lastRetainedSweepAt, now.timeIntervalSince(last) < retainedSweepInterval { return }
        lastRetainedSweepAt = now

        for record in endpointStore.retainedDeletedEndpoints
        where Self.isRetainedRecordExpired(deletedAt: record.deletedAt, now: now) {
            historyStore.removeHistory(for: record.id)
            dailyStatsStore.removeStats(for: record.id)
            versionStore.removeState(for: record.id)
            endpointStore.removeRetainedEndpointRecord(id: record.id)
        }
    }

    private func updateOverallStatus() {
        overallStatus = Self.overallStatus(lastResults: endpointStore.endpoints.map { historyStore.lastResult(for: $0.id) })
    }

    /// `nil` entries are endpoints without a result yet. Any down → `.down`, else any degraded →
    /// `.degraded`, else `.healthy`; `.unknown` when nothing has been checked.
    nonisolated static func overallStatus(lastResults: [HealthCheckResult?]) -> OverallStatus {
        let results = lastResults.compactMap { $0 }
        guard !results.isEmpty else { return .unknown }
        if results.contains(where: { !$0.isHealthy }) { return .down }
        if results.contains(where: { $0.isDegraded }) { return .degraded }
        return .healthy
    }

    // MARK: - Health transitions

    /// Transition between two consecutive results worth notifying about. No previous result means
    /// no transition (the first check never notifies). Down/recovered behave as before; degraded
    /// adds healthy → degraded and degraded → healthy. Degraded → down is a plain `.down`, and
    /// down → degraded is a single `.recovered` carrying the degraded reason.
    nonisolated static func healthTransition(previous: HealthCheckResult?, current: HealthCheckResult) -> HealthTransition? {
        guard let previous else { return nil }
        switch (EndpointHealthState(previous), EndpointHealthState(current)) {
        case (.healthy, .down), (.degraded, .down):
            return .down(reason: current.failureReason)
        case (.down, .healthy):
            return .recovered(degradedReason: nil)
        case (.down, .degraded):
            return .recovered(degradedReason: current.failureReason ?? "Degraded")
        case (.healthy, .degraded):
            return .degraded(reason: current.failureReason)
        case (.degraded, .healthy):
            return .noLongerDegraded
        default:
            return nil
        }
    }

    /// Down and degraded follow "notifications enabled"; recovered and no-longer-degraded also need
    /// "notify on recovery". Snooze suppresses everything.
    nonisolated static func shouldNotify(_ transition: HealthTransition, notificationsEnabled: Bool, notifyOnRecovery: Bool,
                                         isSnoozed: Bool) -> Bool {
        guard notificationsEnabled, !isSnoozed else { return false }
        switch transition {
        case .down, .degraded: return true
        case .recovered, .noLongerDegraded: return notifyOnRecovery
        }
    }

    /// Auto version tracking applies to health-standard endpoints without an enabled version check.
    nonisolated static func usesAutoVersion(_ endpoint: Endpoint) -> Bool {
        endpoint.healthStandard && endpoint.checkType == .http && endpoint.versionCheck?.isEnabled != true
    }

    // MARK: - Raw networking (no actor-isolated state touched here beyond value types)

    struct RawFetchResult {
        let statusCode: Int
        let data: Data
        let elapsedMs: Int
        /// `Content-Type` response header — used to spot health-standard responses in the form.
        var contentType: String? = nil
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
            return .success(RawFetchResult(statusCode: httpResponse.statusCode, data: data, elapsedMs: elapsedMs,
                                           contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")))
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
        await executeCheckDetailed(endpoint: endpoint, timeout: timeout, secret: secret, session: session).result
    }

    struct CheckOutcome {
        let result: HealthCheckResult
        /// Parsed body for health-standard endpoints when it could be read (components, version).
        let standardResponse: HealthStandardResponse?
    }

    /// `executeCheck` plus the parsed health-standard body, which `performCheck` needs for the
    /// Components section and auto version tracking.
    nonisolated static func executeCheckDetailed(endpoint: Endpoint, timeout: TimeInterval, secret: String? = nil,
                                                 session: URLSession = .shared) async -> CheckOutcome {
        if endpoint.checkType == .tcp {
            return CheckOutcome(result: await executeTCPCheck(endpoint: endpoint, timeout: timeout), standardResponse: nil)
        }

        let headers = authHeaders(type: endpoint.authType, username: endpoint.authUsername, secret: secret, headerName: endpoint.authHeaderName)
        switch await performRequest(url: endpoint.url, timeout: timeout, headers: headers, session: session) {
        case .failure(let error):
            let result = HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: false,
                                           responseTimeMs: error.elapsedMs, statusCode: nil, failureReason: error.displayMessage)
            return CheckOutcome(result: result, standardResponse: nil)
        case .success(let raw):
            guard endpoint.healthStandard else {
                return CheckOutcome(result: evaluateStatusAndAssertions(raw, endpoint: endpoint), standardResponse: nil)
            }
            // expectedStatusCode is ignored: the standard defines 200 (pass/warn) and 503 (fail).
            let evaluation = HealthStandard.evaluate(statusCode: raw.statusCode, data: raw.data, assertions: endpoint.jsonAssertions)
            let result = HealthCheckResult(endpointId: endpoint.id, timestamp: Date(), isHealthy: evaluation.isHealthy,
                                           responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode,
                                           failureReason: evaluation.failureReason, isDegraded: evaluation.isDegraded)
            return CheckOutcome(result: result, standardResponse: evaluation.response)
        }
    }

    /// Expected-status-code + JSON-assertion evaluation for endpoints that don't use the health standard.
    private nonisolated static func evaluateStatusAndAssertions(_ raw: RawFetchResult, endpoint: Endpoint) -> HealthCheckResult {
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

    // MARK: - Version check

    /// `checkCount` is 1-based (the health check that just ran). Runs on the 1st, (N+1)th,
    /// (2N+1)th… check, so a newly configured version check doesn't wait N checks for its first
    /// value. `everyN` below 1 is treated as 1.
    nonisolated static func shouldRunVersionCheck(checkCount: Int, everyN: Int) -> Bool {
        guard checkCount >= 1 else { return false }
        return (checkCount - 1) % max(1, everyN) == 0
    }

    /// Applies the user's notification settings to the transitions `VersionStore` reported.
    /// Changes have their own toggle; failure/resolved mirror down/recovered for health checks.
    nonisolated static func versionEventsToNotify(_ events: [VersionCheckEvent], notificationsEnabled: Bool,
                                                  notifyOnRecovery: Bool, notifyOnVersionChange: Bool,
                                                  isSnoozed: Bool) -> [VersionCheckEvent] {
        guard notificationsEnabled, !isSnoozed else { return [] }
        return events.filter { event in
            switch event {
            case .changed: return notifyOnVersionChange
            case .failed: return true
            case .recovered: return notifyOnRecovery
            }
        }
    }

    /// Pure, like `executeCheck`: any 2xx, a JSON body, a readable `versionFieldPath`, and every
    /// assertion passing. The version is still reported when an assertion fails afterwards.
    nonisolated static func executeVersionCheck(config: VersionCheckConfig, timeout: TimeInterval, secret: String? = nil,
                                                session: URLSession = .shared) async -> VersionCheckResult {
        let headers = authHeaders(type: config.authType, username: config.authUsername, secret: secret,
                                  headerName: config.authHeaderName)
        switch await performRequest(url: config.url, timeout: timeout, headers: headers, session: session) {
        case .failure(let error):
            return VersionCheckResult(timestamp: Date(), isSuccess: false, version: nil, failureReason: error.displayMessage,
                                      responseTimeMs: error.elapsedMs, statusCode: nil)
        case .success(let raw):
            return evaluateVersionResponse(raw, config: config)
        }
    }

    /// The response-evaluation half of `executeVersionCheck`, split out so the form's "Test"
    /// button can evaluate the same response it also lists JSON fields from, without a second request.
    nonisolated static func evaluateVersionResponse(_ raw: RawFetchResult, config: VersionCheckConfig,
                                                    now: Date = Date()) -> VersionCheckResult {
        func failure(_ reason: String, version: String? = nil) -> VersionCheckResult {
            VersionCheckResult(timestamp: now, isSuccess: false, version: version, failureReason: reason,
                               responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode)
        }
        guard (200...299).contains(raw.statusCode) else {
            return failure("Expected 2xx, got \(raw.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: raw.data) else {
            return failure("Could not parse JSON")
        }
        let path = config.versionFieldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = extractValue(from: json, path: path) else {
            return failure("Version field \"\(path)\" not found")
        }
        let (passed, reason) = evaluateAssertions(json: json, assertions: config.assertions)
        guard passed else {
            return failure(reason ?? "Assertion failed", version: version)
        }
        return VersionCheckResult(timestamp: now, isSuccess: true, version: version, failureReason: nil,
                                  responseTimeMs: raw.elapsedMs, statusCode: raw.statusCode)
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
    /// Reflects whatever history is currently retained (see `EndpointStore.historyRetentionDays`),
    /// not a fixed calendar window — callers should pair this with the covered time span if that matters.
    nonisolated static func uptimePercentage(results: [HealthCheckResult]) -> Double? {
        guard !results.isEmpty else { return nil }
        let healthyCount = results.filter(\.isHealthy).count
        return Double(healthyCount) / Double(results.count) * 100
    }

    /// Derives down periods from runs of consecutive unhealthy results. `results` must be
    /// chronological, oldest first — the same ordering `HealthHistoryStore.results(for:)` already
    /// returns and `SparklineView`'s `results.suffix(30)` already assumes.
    nonisolated static func incidents(from results: [HealthCheckResult]) -> [Incident] {
        var incidents: [Incident] = []
        var runStart: HealthCheckResult?
        var startBoundaryUncertain = false

        for (index, result) in results.enumerated() {
            if !result.isHealthy {
                if runStart == nil {
                    runStart = result
                    startBoundaryUncertain = (index == 0)
                }
            } else if let start = runStart {
                incidents.append(Incident(startedAt: start.timestamp, endedAt: result.timestamp,
                                           startBoundaryUncertain: startBoundaryUncertain, failureReason: start.failureReason))
                runStart = nil
                startBoundaryUncertain = false
            }
        }
        if let start = runStart {
            incidents.append(Incident(startedAt: start.timestamp, endedAt: nil,
                                       startBoundaryUncertain: startBoundaryUncertain, failureReason: start.failureReason))
        }
        return incidents
    }

    /// CSV export of raw history for one endpoint — header row + one row per result. The only
    /// free-text field (`failureReason`) is escaped per RFC4180 (quote-wrapped if it contains a
    /// comma/quote/newline, internal quotes doubled).
    nonisolated static func csv(for results: [HealthCheckResult], endpointName: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        var lines = ["endpoint,timestamp,isHealthy,responseTimeMs,statusCode,failureReason"]
        for result in results {
            let fields = [
                csvEscape(endpointName),
                isoFormatter.string(from: result.timestamp),
                result.isHealthy ? "true" : "false",
                result.responseTimeMs.map(String.init) ?? "",
                result.statusCode.map(String.init) ?? "",
                csvEscape(result.failureReason ?? ""),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Public status page export

    /// Point-in-time snapshot of one endpoint's health, already resolved by the caller from
    /// `HealthHistoryStore`/`Endpoint` (mirrors `csv(for:endpointName:)`'s pattern of taking
    /// already-fetched data rather than this type touching stores/UserDefaults itself).
    /// `isHealthy`/`uptimePercentage` are `nil` when there's no history yet, matching
    /// `uptimePercentage(results:)`'s own nil-for-empty-history convention.
    struct EndpointStatusSummary: Codable, Equatable {
        let name: String
        let group: String?
        let isHealthy: Bool?
        /// Up but reporting `warn` (Zext Health Standard). Only meaningful when `isHealthy == true`.
        let isDegraded: Bool
        let uptimePercentage: Double?
        let lastCheckedAt: Date?
        let isSnoozed: Bool

        init(name: String, group: String?, isHealthy: Bool?, isDegraded: Bool = false, uptimePercentage: Double?,
             lastCheckedAt: Date?, isSnoozed: Bool) {
            self.name = name
            self.group = group
            self.isHealthy = isHealthy
            self.isDegraded = isDegraded
            self.uptimePercentage = uptimePercentage
            self.lastCheckedAt = lastCheckedAt
            self.isSnoozed = isSnoozed
        }

        /// `nil` when there's no history yet.
        var state: EndpointHealthState? {
            guard let isHealthy else { return nil }
            if !isHealthy { return .down }
            return isDegraded ? .degraded : .healthy
        }
    }

    private struct StatusPagePayload: Codable {
        let generatedAt: Date
        let endpoints: [EndpointStatusSummary]
    }

    /// Builds a single, self-contained HTML status page — all CSS inline, no external
    /// stylesheets/fonts/scripts/images — so it can be dropped onto any static host (GitHub Pages,
    /// S3, etc.) as-is, alongside the sibling JSON from `statusPageJSON`. `name`/`group` are
    /// user-entered free text, so they're HTML-escaped the same way `csv(for:)` escapes
    /// `failureReason` for CSV.
    nonisolated static func statusPageHTML(summaries: [EndpointStatusSummary], generatedAt: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let summaryLine = statusPageSummaryLine(summaries)
        let rows = summaries.isEmpty
            ? "<p class=\"empty\">No endpoints configured.</p>"
            : summaries.map { statusRowHTML(for: $0, dateFormatter: dateFormatter) }.joined(separator: "\n")
        let generatedAtText = dateFormatter.string(from: generatedAt)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Endpoint Status</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #f5f5f7;
          --card-bg: #ffffff;
          --text: #1d1d1f;
          --text-secondary: #6e6e73;
          --border: #d2d2d7;
          --green: #34c759;
          --red: #ff3b30;
          --orange: #ff9500;
          --gray: #8e8e93;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #000000;
            --card-bg: #1c1c1e;
            --text: #f5f5f7;
            --text-secondary: #98989d;
            --border: #38383a;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 32px 16px;
          background: var(--bg);
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        }
        .container { max-width: 720px; margin: 0 auto; }
        h1 { font-size: 1.4rem; margin: 0 0 6px; }
        .summary { font-size: 1rem; color: var(--text-secondary); margin: 0 0 24px; }
        .empty { color: var(--text-secondary); }
        .endpoint {
          display: flex;
          align-items: center;
          gap: 12px;
          padding: 14px 16px;
          background: var(--card-bg);
          border: 1px solid var(--border);
          border-radius: 10px;
          margin-bottom: 10px;
          flex-wrap: wrap;
        }
        .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
        .dot.healthy { background: var(--green); }
        .dot.down { background: var(--red); }
        /* Diamond, not a circle: degraded differs by shape too, not just color. */
        .dot.degraded { background: var(--orange); border-radius: 2px; transform: rotate(45deg) scale(0.85); }
        .dot.unknown { background: var(--gray); }
        .name-block { flex: 1 1 200px; min-width: 0; }
        .name { font-weight: 600; }
        .group { font-size: 0.8rem; color: var(--text-secondary); margin-top: 2px; }
        .snoozed-badge {
          font-size: 0.7rem;
          padding: 2px 8px;
          margin-left: 6px;
          border-radius: 10px;
          background: var(--border);
          color: var(--text-secondary);
          white-space: nowrap;
        }
        .meta { font-size: 0.85rem; color: var(--text-secondary); text-align: right; }
        footer { margin-top: 24px; font-size: 0.8rem; color: var(--text-secondary); text-align: center; }
        @media (max-width: 480px) {
          .endpoint { flex-direction: column; align-items: flex-start; }
          .meta { text-align: left; }
        }
        </style>
        </head>
        <body>
        <div class="container">
        <h1>Endpoint Status</h1>
        <p class="summary">\(htmlEscape(summaryLine))</p>
        <div class="endpoints">
        \(rows)
        </div>
        <footer>Generated at \(htmlEscape(generatedAtText))</footer>
        </div>
        </body>
        </html>
        """
    }

    private nonisolated static func statusRowHTML(for summary: EndpointStatusSummary, dateFormatter: DateFormatter) -> String {
        let statusClass: String
        let statusLabel: String
        switch summary.state {
        case .healthy: statusClass = "healthy"; statusLabel = "Healthy"
        case .degraded: statusClass = "degraded"; statusLabel = "Degraded"
        case .down: statusClass = "down"; statusLabel = "Down"
        case nil: statusClass = "unknown"; statusLabel = "No data yet"
        }

        let uptimeText = summary.uptimePercentage.map { String(format: "%.1f%% uptime", $0) } ?? "No uptime data"
        let lastCheckedText = summary.lastCheckedAt.map { dateFormatter.string(from: $0) } ?? "Never checked"
        let groupHTML = summary.group.map { "<div class=\"group\">\(htmlEscape($0))</div>" } ?? ""
        let snoozedHTML = summary.isSnoozed ? "<span class=\"snoozed-badge\">Snoozed</span>" : ""

        return """
        <div class="endpoint">
          <span class="dot \(statusClass)" title="\(htmlEscape(statusLabel))"></span>
          <div class="name-block">
            <div class="name">\(htmlEscape(summary.name))\(snoozedHTML)</div>
            \(groupHTML)
          </div>
          <div class="meta">
            <div>\(htmlEscape(statusLabel)) · \(htmlEscape(uptimeText))</div>
            <div>Last checked: \(htmlEscape(lastCheckedText))</div>
          </div>
        </div>
        """
    }

    /// e.g. "3 of 4 endpoints healthy", or "2 of 4 endpoints healthy · 1 degraded" — degraded
    /// endpoints are up but not counted as healthy.
    nonisolated static func statusPageSummaryLine(_ summaries: [EndpointStatusSummary]) -> String {
        let healthyCount = summaries.filter { $0.state == .healthy }.count
        let degradedCount = summaries.filter { $0.state == .degraded }.count
        let base = "\(healthyCount) of \(summaries.count) endpoint\(summaries.count == 1 ? "" : "s") healthy"
        return degradedCount > 0 ? "\(base) · \(degradedCount) degraded" : base
    }

    /// Minimal HTML entity escaping for user-entered free text (endpoint name/group) — no existing
    /// helper for this in the codebase (unlike `csvEscape` for CSV), so this is the HTML equivalent.
    /// Order matters: `&` must be escaped first so it doesn't double-escape the entities below.
    private nonisolated static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// JSON sibling of `statusPageHTML` — the same summaries, machine-readable, as a top-level
    /// object with `generatedAt` plus an `endpoints` array (camelCase, ISO8601 dates via
    /// `JSONEncoder`, no hand-built string like the HTML above needs).
    nonisolated static func statusPageJSON(summaries: [EndpointStatusSummary], generatedAt: Date) -> Data {
        let payload = StatusPagePayload(generatedAt: generatedAt, endpoints: summaries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
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
    nonisolated static func fetchCertificateExpiry(
        host: String, port: UInt16 = 443, timeout: TimeInterval = 10, parameters: NWParameters = .tls
    ) async -> Date? {
        await withCheckedContinuation { continuation in
            let resumer = CertFetchResumer(continuation: continuation)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                resumer.resumeOnce(nil)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
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

    nonisolated static func notAfterDate(from certificate: SecCertificate) -> Date? {
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

    /// Whether a `RetainedEndpointRecord` deleted at `deletedAt` has passed its retention window
    /// and should be purged (see `pruneExpiredRetainedEndpoints`).
    nonisolated static func isRetainedRecordExpired(deletedAt: Date, retentionDays: Int = EndpointStore.retainedDataExpiryDays, now: Date = Date()) -> Bool {
        now.timeIntervalSince(deletedAt) > TimeInterval(retentionDays * 24 * 60 * 60)
    }

    /// Whether `endpoint`'s notifications should currently be suppressed for planned maintenance.
    /// Checks/history/stats recording are unaffected — only `performCheck`'s notification calls
    /// consult this.
    nonisolated static func isSnoozed(_ endpoint: Endpoint, now: Date = Date()) -> Bool {
        guard let snoozedUntil = endpoint.snoozedUntil else { return false }
        return snoozedUntil > now
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
