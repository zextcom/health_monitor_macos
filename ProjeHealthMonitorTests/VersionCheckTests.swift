import XCTest
import UserNotifications
@testable import ProjeHealthMonitor

// MARK: - Model / Codable

final class VersionCheckModelTests: XCTestCase {
    private let versionURL = URL(string: "https://example.test/version")!

    func testConfigDecodesWithDefaultsWhenOptionalKeysMissing() throws {
        let json = #"{"url":"https://example.test/version","versionFieldPath":"data.version"}"#
        let config = try JSONDecoder().decode(VersionCheckConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.everyNChecks, VersionCheckConfig.defaultEveryNChecks)
        XCTAssertEqual(config.versionFieldPath, "data.version")
        XCTAssertEqual(config.assertions, [])
        XCTAssertEqual(config.authType, .none)
        XCTAssertNil(config.authUsername)
        XCTAssertNil(config.authHeaderName)
    }

    func testConfigClampsNonPositiveEveryNToOne() throws {
        let json = #"{"url":"https://example.test/version","versionFieldPath":"v","everyNChecks":0}"#
        let config = try JSONDecoder().decode(VersionCheckConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.everyNChecks, 1)
    }

    func testLegacyEndpointWithoutVersionCheckDecodesAsNil() throws {
        let json = #"{"id":"6B1A2E1F-1D3B-4C9A-9C1B-1C2D3E4F5A6B","name":"API","url":"https://example.test/health"}"#
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(json.utf8))
        XCTAssertNil(endpoint.versionCheck)
    }

    func testEndpointRoundTripsVersionCheck() throws {
        let config = VersionCheckConfig(isEnabled: false, url: versionURL, everyNChecks: 7, versionFieldPath: "build.version",
                                        assertions: [JSONAssertion(path: "env", expectedValue: "prod", matchMode: .contains)],
                                        authType: .customHeader, authHeaderName: "X-Key")
        let endpoint = Endpoint(name: "API", url: URL(string: "https://example.test/health")!, versionCheck: config)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: JSONEncoder().encode(endpoint))
        XCTAssertEqual(decoded.versionCheck, config)
        XCTAssertEqual(decoded, endpoint)
    }

    func testVersionSecretAccountDiffersFromEndpointAccount() {
        let id = UUID()
        XCTAssertNotEqual(VersionCheckConfig.secretAccount(for: id), id.uuidString)
        XCTAssertTrue(VersionCheckConfig.secretAccount(for: id).hasPrefix(id.uuidString))
    }

    func testCleanedAssertionsTrimsDropsBlankAndRejectsHalfFilled() {
        let rows = [
            JSONAssertion(path: "  a ", expectedValue: " 1 "),
            JSONAssertion(path: "", expectedValue: "  "),
        ]
        XCTAssertEqual(JSONAssertion.cleaned(rows)?.map(\.path), ["a"])
        XCTAssertEqual(JSONAssertion.cleaned(rows)?.map(\.expectedValue), ["1"])
        XCTAssertNil(JSONAssertion.cleaned([JSONAssertion(path: "a", expectedValue: "")]))
    }
}

// MARK: - Execution / evaluation

final class VersionCheckExecutionTests: XCTestCase {
    private var session: URLSession!
    private let versionURL = URL(string: "https://example.test/version")!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    private func config(path: String = "data.version", assertions: [JSONAssertion] = [],
                        authType: AuthType = .none, headerName: String? = nil) -> VersionCheckConfig {
        VersionCheckConfig(url: versionURL, versionFieldPath: path, assertions: assertions, authType: authType,
                           authHeaderName: headerName)
    }

    private func raw(_ status: Int, _ body: String) -> HealthCheckService.RawFetchResult {
        HealthCheckService.RawFetchResult(statusCode: status, data: Data(body.utf8), elapsedMs: 12)
    }

    func testSuccessReadsVersion() {
        let result = HealthCheckService.evaluateVersionResponse(raw(200, #"{"data":{"version":"1.4.2"}}"#), config: config())
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.version, "1.4.2")
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.responseTimeMs, 12)
    }

    func testAnyTwoHundredStatusIsAccepted() {
        let result = HealthCheckService.evaluateVersionResponse(raw(204, #"{"data":{"version":"1"}}"#), config: config())
        XCTAssertTrue(result.isSuccess)
    }

    func testNumericVersionIsStringified() {
        let result = HealthCheckService.evaluateVersionResponse(raw(200, #"{"build":42}"#), config: config(path: "build"))
        XCTAssertEqual(result.version, "42")
    }

    func testNonTwoHundredFails() {
        let result = HealthCheckService.evaluateVersionResponse(raw(503, #"{"data":{"version":"1"}}"#), config: config())
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, "Expected 2xx, got 503")
        XCTAssertNil(result.version)
    }

    func testInvalidJSONFails() {
        let result = HealthCheckService.evaluateVersionResponse(raw(200, "<html>"), config: config())
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, "Could not parse JSON")
    }

    func testMissingVersionFieldFails() {
        let result = HealthCheckService.evaluateVersionResponse(raw(200, #"{"data":{}}"#), config: config())
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureReason, "Version field \"data.version\" not found")
    }

    func testFailedAssertionStillReportsVersion() {
        let assertion = JSONAssertion(path: "env", expectedValue: "production")
        let result = HealthCheckService.evaluateVersionResponse(
            raw(200, #"{"data":{"version":"2.0.0"},"env":"staging"}"#), config: config(assertions: [assertion]))
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.version, "2.0.0")
        XCTAssertEqual(result.failureReason, "\"env\" = staging, expected production")
    }

    func testPassingAssertionsSucceed() {
        let assertions = [JSONAssertion(path: "env", expectedValue: "prod", matchMode: .contains),
                          JSONAssertion(path: "data.version", expectedValue: "^2\\.", matchMode: .regex)]
        let result = HealthCheckService.evaluateVersionResponse(
            raw(200, #"{"data":{"version":"2.1.0"},"env":"production"}"#), config: config(assertions: assertions))
        XCTAssertTrue(result.isSuccess)
    }

    func testExecuteSendsVersionAuthHeaderAndUsesVersionURL() async {
        nonisolated(unsafe) var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":{"version":"3.0"}}"#.utf8))
        }
        let result = await HealthCheckService.executeVersionCheck(
            config: config(authType: .customHeader, headerName: "X-Version-Key"), timeout: 5, secret: "s3cret", session: session)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.version, "3.0")
        XCTAssertEqual(capturedRequest?.url, versionURL)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Version-Key"), "s3cret")
    }

    func testExecuteReportsNetworkFailure() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let result = await HealthCheckService.executeVersionCheck(config: config(), timeout: 5, session: session)
        XCTAssertFalse(result.isSuccess)
        XCTAssertNil(result.version)
        XCTAssertNil(result.statusCode)
        XCTAssertNotNil(result.failureReason)
    }
}

// MARK: - Scheduling / notification gating

final class VersionCheckSchedulingTests: XCTestCase {
    func testRunsOnFirstAndEveryNthCheckAfter() {
        let runs = (1...12).filter { HealthCheckService.shouldRunVersionCheck(checkCount: $0, everyN: 5) }
        XCTAssertEqual(runs, [1, 6, 11])
    }

    func testEveryOneRunsEveryTime() {
        XCTAssertTrue((1...5).allSatisfy { HealthCheckService.shouldRunVersionCheck(checkCount: $0, everyN: 1) })
    }

    func testNonPositiveEveryNTreatedAsOne() {
        XCTAssertTrue(HealthCheckService.shouldRunVersionCheck(checkCount: 3, everyN: 0))
        XCTAssertTrue(HealthCheckService.shouldRunVersionCheck(checkCount: 3, everyN: -2))
    }

    func testZeroCheckCountNeverRuns() {
        XCTAssertFalse(HealthCheckService.shouldRunVersionCheck(checkCount: 0, everyN: 5))
    }

    private let allEvents: [VersionCheckEvent] = [.changed(from: "1", to: "2"), .failed(reason: "x"), .recovered]

    func testAllEventsPassWhenEverythingEnabled() {
        let events = HealthCheckService.versionEventsToNotify(allEvents, notificationsEnabled: true, notifyOnRecovery: true,
                                                              notifyOnVersionChange: true, isSnoozed: false)
        XCTAssertEqual(events, allEvents)
    }

    func testNothingWhenNotificationsDisabledOrSnoozed() {
        XCTAssertEqual(HealthCheckService.versionEventsToNotify(allEvents, notificationsEnabled: false, notifyOnRecovery: true,
                                                                notifyOnVersionChange: true, isSnoozed: false), [])
        XCTAssertEqual(HealthCheckService.versionEventsToNotify(allEvents, notificationsEnabled: true, notifyOnRecovery: true,
                                                                notifyOnVersionChange: true, isSnoozed: true), [])
    }

    func testChangeToggleOnlyGatesChanges() {
        let events = HealthCheckService.versionEventsToNotify(allEvents, notificationsEnabled: true, notifyOnRecovery: true,
                                                              notifyOnVersionChange: false, isSnoozed: false)
        XCTAssertEqual(events, [.failed(reason: "x"), .recovered])
    }

    func testRecoveryToggleOnlyGatesRecovery() {
        let events = HealthCheckService.versionEventsToNotify(allEvents, notificationsEnabled: true, notifyOnRecovery: false,
                                                              notifyOnVersionChange: true, isSnoozed: false)
        XCTAssertEqual(events, [.changed(from: "1", to: "2"), .failed(reason: "x")])
    }
}

// MARK: - VersionStore transitions & persistence

@MainActor
final class VersionStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func success(_ version: String, at seconds: TimeInterval = 0) -> VersionCheckResult {
        VersionCheckResult(timestamp: Date(timeIntervalSince1970: seconds), isSuccess: true, version: version,
                           failureReason: nil, responseTimeMs: 10, statusCode: 200)
    }

    private func failure(_ reason: String = "Timed out", version: String? = nil, at seconds: TimeInterval = 0) -> VersionCheckResult {
        VersionCheckResult(timestamp: Date(timeIntervalSince1970: seconds), isSuccess: false, version: version,
                           failureReason: reason, responseTimeMs: nil, statusCode: nil)
    }

    func testFirstSuccessRecordsVersionWithoutEvents() {
        let (state, events) = VersionStore.apply(success("1.0", at: 10), to: nil)
        XCTAssertEqual(events, [])
        XCTAssertEqual(state.currentVersion, "1.0")
        XCTAssertEqual(state.history.count, 1)
        XCTAssertFalse(state.isFailing)
    }

    func testFirstFailureDoesNotNotify() {
        let (state, events) = VersionStore.apply(failure(), to: nil)
        XCTAssertEqual(events, [])
        XCTAssertTrue(state.isFailing)
        XCTAssertNil(state.currentVersion)
    }

    func testSameVersionExtendsLastSeenInsteadOfAppending() {
        let (first, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (second, events) = VersionStore.apply(success("1.0", at: 50), to: first)
        XCTAssertEqual(events, [])
        XCTAssertEqual(second.history.count, 1)
        XCTAssertEqual(second.history[0].firstSeenAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(second.history[0].lastSeenAt, Date(timeIntervalSince1970: 50))
    }

    func testVersionChangeEmitsChangedAndAppends() {
        let (first, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (second, events) = VersionStore.apply(success("1.1", at: 20), to: first)
        XCTAssertEqual(events, [.changed(from: "1.0", to: "1.1")])
        XCTAssertEqual(second.history.map(\.value), ["1.0", "1.1"])
        XCTAssertEqual(second.currentVersion, "1.1")
    }

    func testWhitespaceOnlyDifferenceIsNotAChange() {
        let (first, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (_, events) = VersionStore.apply(success(" 1.0\n", at: 20), to: first)
        XCTAssertEqual(events, [])
    }

    func testFailureTransitionThenRecovery() {
        let (ok, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (failed, failEvents) = VersionStore.apply(failure("Timed out", at: 20), to: ok)
        XCTAssertEqual(failEvents, [.failed(reason: "Timed out")])
        XCTAssertTrue(failed.isFailing)
        XCTAssertEqual(failed.currentVersion, "1.0", "a failed run must not hide the last known version")

        let (stillFailed, repeatEvents) = VersionStore.apply(failure("Timed out", at: 30), to: failed)
        XCTAssertEqual(repeatEvents, [], "repeated failures notify only once")

        let (recovered, recoverEvents) = VersionStore.apply(success("1.0", at: 40), to: stillFailed)
        XCTAssertEqual(recoverEvents, [.recovered])
        XCTAssertFalse(recovered.isFailing)
    }

    func testDeployThroughFailureReportsRecoveryAndChange() {
        let (ok, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (failed, _) = VersionStore.apply(failure(at: 20), to: ok)
        let (_, events) = VersionStore.apply(success("2.0", at: 30), to: failed)
        XCTAssertEqual(events, [.recovered, .changed(from: "1.0", to: "2.0")])
    }

    func testAssertionFailureWithNewVersionStillTracksChange() {
        let (ok, _) = VersionStore.apply(success("1.0", at: 10), to: nil)
        let (state, events) = VersionStore.apply(failure("env mismatch", version: "1.1", at: 20), to: ok)
        XCTAssertEqual(events, [.failed(reason: "env mismatch"), .changed(from: "1.0", to: "1.1")])
        XCTAssertEqual(state.currentVersion, "1.1")
    }

    func testHistoryIsCappedKeepingNewest() {
        var state: EndpointVersionState?
        for index in 0..<8 {
            state = VersionStore.apply(success("v\(index)", at: TimeInterval(index)), to: state, historyLimit: 5).0
        }
        XCTAssertEqual(state?.history.map(\.value), ["v3", "v4", "v5", "v6", "v7"])
    }

    func testDefaultHistoryLimitIsFifty() {
        XCTAssertEqual(VersionStore.historyLimit, 50)
    }

    func testRecordPersistsAndReloads() {
        let fileURL = tempDirectory.appendingPathComponent("versions.json")
        let id = UUID()
        let store = VersionStore(fileURL: fileURL)
        store.record(success("1.0", at: 10), for: id)
        let events = store.record(success("1.1", at: 20), for: id)
        XCTAssertEqual(events, [.changed(from: "1.0", to: "1.1")])

        let reloaded = VersionStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.state(for: id)?.history.map(\.value), ["1.0", "1.1"])
        XCTAssertEqual(reloaded.state(for: id)?.lastResult, success("1.1", at: 20))
    }

    func testRemoveStatePersists() {
        let fileURL = tempDirectory.appendingPathComponent("versions.json")
        let id = UUID()
        let store = VersionStore(fileURL: fileURL)
        store.record(success("1.0"), for: id)
        store.removeState(for: id)
        XCTAssertNil(store.state(for: id))
        XCTAssertNil(VersionStore(fileURL: fileURL).state(for: id))
    }
}

// MARK: - Form draft validation

final class VersionCheckDraftTests: XCTestCase {
    private func validDraft() -> VersionCheckDraft {
        var draft = VersionCheckDraft()
        draft.isEnabled = true
        draft.urlString = " https://example.test/version "
        draft.everyNChecks = "5"
        draft.versionFieldPath = " data.version "
        return draft
    }

    func testValidDraftProducesTrimmedConfig() throws {
        let output = try validDraft().validate(original: nil).get()
        XCTAssertEqual(output.config?.url, URL(string: "https://example.test/version"))
        XCTAssertEqual(output.config?.versionFieldPath, "data.version")
        XCTAssertEqual(output.config?.everyNChecks, 5)
        XCTAssertEqual(output.config?.isEnabled, true)
        XCTAssertEqual(output.secretUpdate, .unchanged)
    }

    func testRoundTripsFromExistingConfig() throws {
        let config = VersionCheckConfig(url: URL(string: "https://example.test/v")!, everyNChecks: 3, versionFieldPath: "v",
                                        assertions: [JSONAssertion(path: "env", expectedValue: "prod")])
        let output = try VersionCheckDraft(config: config).validate(original: config).get()
        XCTAssertEqual(output.config?.url, config.url)
        XCTAssertEqual(output.config?.everyNChecks, 3)
        XCTAssertEqual(output.config?.assertions.map(\.path), ["env"])
    }

    func testRejectsInvalidURLs() {
        for urlString in ["", "not a url", "ftp://example.test/v", "tcp://db:5432"] {
            var draft = validDraft()
            draft.urlString = urlString
            XCTAssertEqual(draft.validate(original: nil), .failure(.invalidURL), urlString)
        }
    }

    func testRejectsInvalidFrequency() {
        for value in ["0", "-1", "abc", "1001", ""] {
            var draft = validDraft()
            draft.everyNChecks = value
            XCTAssertEqual(draft.validate(original: nil), .failure(.invalidFrequency), value)
        }
    }

    func testRequiresVersionField() {
        var draft = validDraft()
        draft.versionFieldPath = "   "
        XCTAssertEqual(draft.validate(original: nil), .failure(.missingVersionField))
    }

    func testRejectsHalfFilledAssertion() {
        var draft = validDraft()
        draft.assertions = [JSONAssertion(path: "env", expectedValue: "")]
        XCTAssertEqual(draft.validate(original: nil), .failure(.incompleteAssertion))
    }

    func testCustomHeaderNeedsHeaderName() {
        var draft = validDraft()
        draft.authType = .customHeader
        draft.secret = "x"
        XCTAssertEqual(draft.validate(original: nil), .failure(.missingHeaderName))
    }

    func testNewAuthRequiresSecret() {
        var draft = validDraft()
        draft.authType = .bearerToken
        XCTAssertEqual(draft.validate(original: nil), .failure(.missingSecret(.bearerToken)))
    }

    func testTypedSecretIsSet() throws {
        var draft = validDraft()
        draft.authType = .basicAuth
        draft.authUsername = " admin "
        draft.secret = " pw "
        let output = try draft.validate(original: nil).get()
        XCTAssertEqual(output.secretUpdate, .set("pw"))
        XCTAssertEqual(output.config?.authUsername, "admin")
    }

    func testBlankSecretKeepsExistingWhenAuthTypeUnchanged() throws {
        let original = VersionCheckConfig(url: URL(string: "https://example.test/v")!, versionFieldPath: "v", authType: .bearerToken)
        var draft = VersionCheckDraft(config: original)
        draft.secret = ""
        XCTAssertEqual(try draft.validate(original: original).get().secretUpdate, .unchanged)
    }

    func testChangingAuthTypeRequiresNewSecret() {
        let original = VersionCheckConfig(url: URL(string: "https://example.test/v")!, versionFieldPath: "v", authType: .bearerToken)
        var draft = VersionCheckDraft(config: original)
        draft.authType = .customHeader
        draft.authHeaderName = "X-Key"
        XCTAssertEqual(draft.validate(original: original), .failure(.missingSecret(.customHeader)))
    }

    func testSwitchingAuthToNoneClearsExistingSecret() throws {
        let original = VersionCheckConfig(url: URL(string: "https://example.test/v")!, versionFieldPath: "v", authType: .bearerToken)
        var draft = VersionCheckDraft(config: original)
        draft.authType = .none
        XCTAssertEqual(try draft.validate(original: original).get().secretUpdate, .cleared)
    }

    func testDisabledDraftWithURLIsKeptPausedEvenIfIncomplete() throws {
        var draft = validDraft()
        draft.isEnabled = false
        draft.versionFieldPath = ""
        draft.everyNChecks = "nope"
        draft.assertions = [JSONAssertion(path: "env", expectedValue: "")]
        let output = try draft.validate(original: nil).get()
        XCTAssertEqual(output.config?.isEnabled, false)
        XCTAssertEqual(output.config?.everyNChecks, VersionCheckConfig.defaultEveryNChecks)
        XCTAssertEqual(output.config?.assertions, [])
    }

    func testDisabledDraftWithoutURLDropsConfigAndExistingSecret() throws {
        let original = VersionCheckConfig(url: URL(string: "https://example.test/v")!, versionFieldPath: "v", authType: .bearerToken)
        var draft = VersionCheckDraft()
        draft.isEnabled = false
        let output = try draft.validate(original: original).get()
        XCTAssertNil(output.config)
        XCTAssertEqual(output.secretUpdate, .cleared)
    }

    func testEmptyDraftInAddModeSavesNothing() throws {
        let output = try VersionCheckDraft().validate(original: nil).get()
        XCTAssertNil(output.config)
        XCTAssertEqual(output.secretUpdate, .unchanged)
    }
}

// MARK: - Badge text

final class VersionBadgeTests: XCTestCase {
    func testPrefixesNumericVersionsWithV() {
        XCTAssertEqual(VersionBadge.displayText(for: "1.5.0"), "v1.5.0")
    }

    func testLeavesPrefixedAndNonNumericValuesAlone() {
        XCTAssertEqual(VersionBadge.displayText(for: "v1.5.0"), "v1.5.0")
        XCTAssertEqual(VersionBadge.displayText(for: "main-abc123"), "main-abc123")
    }

    func testTruncatesLongValues() {
        let sha = "3f9a1c7e2b8d4f60a1b2c3d4e5f6a7b8c9d0e1f2"
        let text = VersionBadge.displayText(for: sha, maxLength: 10)
        XCTAssertEqual(text.count, 10)
        XCTAssertTrue(text.hasSuffix("…"))
    }
}

// MARK: - Notifications & settings

private final class RecordingNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    private(set) var addedRequests: [UNNotificationRequest] = []
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws { addedRequests.append(request) }
}

final class VersionNotificationTests: XCTestCase {
    func testVersionChangedContent() async {
        let center = RecordingNotificationCenter()
        await NotificationService(center: center).notifyVersionChangedAsync(endpointName: "API", from: "1.4.2", to: "1.5.0")
        XCTAssertEqual(center.addedRequests.first?.content.title, "API version changed")
        XCTAssertEqual(center.addedRequests.first?.content.body, "1.4.2 → 1.5.0")
    }

    func testVersionFailedAndRecoveredContent() async {
        let center = RecordingNotificationCenter()
        let service = NotificationService(center: center)
        await service.notifyVersionCheckFailedAsync(endpointName: "API", reason: "Timed out")
        await service.notifyVersionCheckRecoveredAsync(endpointName: "API")
        XCTAssertEqual(center.addedRequests.map(\.content.title), ["API version check failed", "API version check resolved"])
        XCTAssertEqual(center.addedRequests.first?.content.body, "Timed out")
    }

    @MainActor
    func testNotifyOnVersionChangeDefaultsOnAndPersists() {
        let suite = "VersionNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = EndpointStore(defaults: defaults)
        XCTAssertTrue(store.notifyOnVersionChange)
        store.notifyOnVersionChange = false
        XCTAssertFalse(EndpointStore(defaults: defaults).notifyOnVersionChange)
    }
}

// MARK: - Backend dashboard decoding

final class DashboardVersionDecodingTests: XCTestCase {
    private func endpointJSON(version: String?) -> Data {
        let versionField = version.map { #","version":\#($0)"# } ?? ""
        return Data(#"{"id":"e1","name":"API","url":"https://x.test","checkType":"http","groupName":null,"isPaused":false,"latestCheck":null,"uptimePercent24h":null,"activeIncident":null\#(versionField)}"#.utf8)
    }

    func testDecodesWithoutVersionFieldFromOlderBackend() throws {
        let info = try JSONDecoder().decode(DashboardEndpointInfo.self, from: endpointJSON(version: nil))
        XCTAssertNil(info.version)
    }

    func testDecodesNullVersion() throws {
        let info = try JSONDecoder().decode(DashboardEndpointInfo.self, from: endpointJSON(version: "null"))
        XCTAssertNil(info.version)
    }

    func testDecodesVersionSummary() throws {
        let json = #"{"isEnabled":true,"current":"2.0.0","isFailing":true,"failureReason":"Timed out","lastCheckedAt":"2026-10-01T10:00:00.000Z"}"#
        let info = try JSONDecoder().decode(DashboardEndpointInfo.self, from: endpointJSON(version: json))
        XCTAssertEqual(info.version?.current, "2.0.0")
        XCTAssertEqual(info.version?.isFailing, true)
        XCTAssertEqual(info.version?.failureReason, "Timed out")
    }
}
