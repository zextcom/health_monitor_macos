import XCTest
import UserNotifications
@testable import ProjeHealthMonitor

// MARK: - Model / Codable

final class HealthStandardModelTests: XCTestCase {
    private let url = URL(string: "https://example.test/health")!

    func testLegacyEndpointDecodesWithHealthStandardOff() throws {
        let json = #"{"id":"6B1A2E1F-1D3B-4C9A-9C1B-1C2D3E4F5A6B","name":"API","url":"https://example.test/health"}"#
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(json.utf8))
        XCTAssertFalse(endpoint.healthStandard)
    }

    func testEndpointRoundTripsHealthStandard() throws {
        let endpoint = Endpoint(name: "API", url: url, healthStandard: true)
        let data = try JSONEncoder().encode(endpoint)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""healthStandard":true"#))
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertTrue(decoded.healthStandard)
        XCTAssertEqual(decoded, endpoint)
    }

    /// Export/import is `[Endpoint]` JSON (EndpointStore.exportData/importEndpoints), so the flag travels with it.
    func testExportImportShapeCarriesHealthStandard() throws {
        let endpoints = [Endpoint(name: "A", url: url, healthStandard: true), Endpoint(name: "B", url: url)]
        let decoded = try JSONDecoder().decode([Endpoint].self, from: JSONEncoder().encode(endpoints))
        XCTAssertEqual(decoded.map(\.healthStandard), [true, false])
    }

    func testLegacyResultDecodesAsNotDegraded() throws {
        let json = #"{"id":"6B1A2E1F-1D3B-4C9A-9C1B-1C2D3E4F5A6B","endpointId":"6B1A2E1F-1D3B-4C9A-9C1B-1C2D3E4F5A6C","timestamp":0,"isHealthy":true,"responseTimeMs":12,"statusCode":200}"#
        let result = try JSONDecoder().decode(HealthCheckResult.self, from: Data(json.utf8))
        XCTAssertFalse(result.isDegraded)
        XCTAssertTrue(result.isHealthy)
        XCTAssertNil(result.failureReason)
    }

    func testResultRoundTripsDegraded() throws {
        let result = HealthCheckResult(endpointId: UUID(), timestamp: Date(timeIntervalSince1970: 100), isHealthy: true,
                                       responseTimeMs: 5, statusCode: 200, failureReason: "Disk", isDegraded: true)
        let decoded = try JSONDecoder().decode(HealthCheckResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.isDegraded)
    }

    func testDownResultIsNeverDegraded() {
        let result = HealthCheckResult(endpointId: UUID(), timestamp: Date(), isHealthy: false, responseTimeMs: nil,
                                       statusCode: 503, failureReason: "x", isDegraded: true)
        XCTAssertFalse(result.isDegraded)
    }
}

// MARK: - Parsing helpers

final class HealthStandardParsingTests: XCTestCase {
    private func json(_ string: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed])
    }

    func testWorstStatusOrdering() {
        XCTAssertEqual(HealthStandardStatus.worst([]), .pass)
        XCTAssertEqual(HealthStandardStatus.worst([.pass, .warn]), .warn)
        XCTAssertEqual(HealthStandardStatus.worst([.warn, .fail, .pass]), .fail)
        XCTAssertTrue(HealthStandardStatus.pass < .warn && HealthStandardStatus.warn < .fail)
    }

    func testParseRequiresObjectWithValidStatus() {
        XCTAssertEqual(try? HealthStandard.parse(json: json("[]")).get(), nil)
        XCTAssertEqual(errorOf(HealthStandard.parse(json: json("[]"))), .notAnObject)
        XCTAssertEqual(errorOf(HealthStandard.parse(json: json("{}"))), .missingStatus)
        XCTAssertEqual(errorOf(HealthStandard.parse(json: json(#"{"status":"ok"}"#))), .invalidStatus("\"ok\""))
        XCTAssertEqual(errorOf(HealthStandard.parse(json: json(#"{"status":null}"#))), .invalidStatus("null"))
        XCTAssertEqual(errorOf(HealthStandard.parse(json: json(#"{"status":"PASS"}"#))), .invalidStatus("\"PASS\""))
    }

    func testParseReadsStandardFieldsLeniently() throws {
        let body = #"{"status":"warn","version":" 1.0 ","releaseId":12345,"output":" Cache unavailable "}"#
        let response = try HealthStandard.parse(json: json(body)).get()
        XCTAssertEqual(response, HealthStandardResponse(status: .warn, version: "1.0", releaseId: "12345",
                                                         output: "Cache unavailable"))
    }

    func testParseIgnoresLegacyChecksAndExtraFields() throws {
        let body = #"""
        {"status":"pass","php":"8.3.23",
         "checks":{"postgres:responseTime":[{"status":"fail","observedValue":12}], "broken":"not-an-array"}}
        """#
        let response = try HealthStandard.parse(json: json(body)).get()
        XCTAssertEqual(response, HealthStandardResponse(status: .pass, version: nil, releaseId: nil, output: nil))
    }

    func testParseClipsLongOutput() throws {
        let long = String(repeating: "x", count: 1000)
        let response = try HealthStandard.parse(json: json(#"{"status":"fail","output":"\#(long)"}"#)).get()
        XCTAssertEqual(response.output?.count, HealthStandard.maxTextLength)
    }

    func testReason() {
        func response(_ status: HealthStandardStatus, output: String? = nil) -> HealthStandardResponse {
            HealthStandardResponse(status: status, version: nil, releaseId: nil, output: output)
        }
        XCTAssertNil(HealthStandard.reason(for: response(.pass, output: "ignored")))
        XCTAssertEqual(HealthStandard.reason(for: response(.fail, output: "DB down")), "DB down")
        XCTAssertEqual(HealthStandard.reason(for: response(.warn)), "Health status \"warn\"")
    }

    func testTrackedVersion() {
        XCTAssertEqual(HealthStandard.trackedVersion(version: "1.4.2", releaseId: "9f2c1ab7e4d3"), "1.4.2 (9f2c1ab)")
        XCTAssertEqual(HealthStandard.trackedVersion(version: "1.4.2", releaseId: nil), "1.4.2")
        XCTAssertEqual(HealthStandard.trackedVersion(version: nil, releaseId: "9f2c1ab7e4d3"), "9f2c1ab7e4d3")
        XCTAssertEqual(HealthStandard.trackedVersion(version: "2.0", releaseId: "b12"), "2.0 (b12)")
        XCTAssertEqual(HealthStandard.trackedVersion(version: "  ", releaseId: " 42 "), "42")
        XCTAssertNil(HealthStandard.trackedVersion(version: nil, releaseId: nil))
        XCTAssertNil(HealthStandard.trackedVersion(version: "", releaseId: " "))
    }

    func testLooksStandard() {
        XCTAssertTrue(HealthStandard.looksStandard(contentType: "application/health+json; charset=utf-8", json: nil))
        XCTAssertTrue(HealthStandard.looksStandard(contentType: "Application/Health+JSON", json: nil))
        XCTAssertTrue(HealthStandard.looksStandard(contentType: "application/json", json: json(#"{"status":"warn"}"#)))
        XCTAssertTrue(HealthStandard.looksStandard(contentType: nil, json: json(#"{"status":"fail"}"#)))
        XCTAssertFalse(HealthStandard.looksStandard(contentType: "application/json", json: json(#"{"status":"ok"}"#)))
        XCTAssertFalse(HealthStandard.looksStandard(contentType: "text/html", json: nil))
        XCTAssertFalse(HealthStandard.looksStandard(contentType: nil, json: json(#"["pass"]"#)))
    }

    func testSummary() {
        let warn = HealthStandard.evaluate(statusCode: 200, data: Data(#"""
            {"status":"warn","version":"1.4.2","releaseId":"9f2c1ab7e4d3","output":"Cache unavailable"}
            """#.utf8))
        XCTAssertEqual(HealthStandard.testSummary(warn), "Status warn · version 1.4.2 (9f2c1ab) · Cache unavailable")
        let pass = HealthStandard.evaluate(statusCode: 200, data: Data(#"{"status":"pass"}"#.utf8))
        XCTAssertEqual(HealthStandard.testSummary(pass), "Status pass")
        let invalid = HealthStandard.evaluate(statusCode: 200, data: Data(#"{"status":"ok"}"#.utf8))
        XCTAssertEqual(HealthStandard.testSummary(invalid), "Invalid health response: invalid status \"ok\"")
    }

    private func errorOf(_ result: Result<HealthStandardResponse, HealthStandardParseError>) -> HealthStandardParseError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

// MARK: - Evaluation matrix

final class HealthStandardEvaluationTests: XCTestCase {
    private func evaluate(_ status: Int, _ body: String, assertions: [JSONAssertion] = []) -> HealthStandard.Evaluation {
        HealthStandard.evaluate(statusCode: status, data: Data(body.utf8), assertions: assertions)
    }

    func testStatusByHTTPMatrix() {
        let cases: [(http: Int, status: String, healthy: Bool, degraded: Bool, reason: String?)] = [
            (200, "pass", true, false, nil),
            (200, "warn", true, true, "Health status \"warn\""),
            (200, "fail", false, false, "Health status \"fail\""),
            (503, "fail", false, false, "Health status \"fail\""),
            (503, "pass", false, false, "Invalid health response: HTTP 503 with status \"pass\""),
            (503, "warn", false, false, "Invalid health response: HTTP 503 with status \"warn\""),
        ]
        for testCase in cases {
            let result = evaluate(testCase.http, #"{"status":"\#(testCase.status)"}"#)
            XCTAssertEqual(result.isHealthy, testCase.healthy, "\(testCase)")
            XCTAssertEqual(result.isDegraded, testCase.degraded, "\(testCase)")
            XCTAssertEqual(result.failureReason, testCase.reason, "\(testCase)")
        }
    }

    func testOtherHTTPStatusesAreDown() {
        for http in [201, 204, 301, 401, 404, 500, 502] {
            let result = evaluate(http, #"{"status":"pass"}"#)
            XCTAssertFalse(result.isHealthy)
            XCTAssertEqual(result.failureReason, "Unexpected HTTP \(http)")
            XCTAssertNil(result.response)
        }
    }

    func testInvalidBodiesAreDown() {
        let cases: [(String, String)] = [
            ("<html>oops</html>", "Invalid health response: body is not valid JSON"),
            ("", "Invalid health response: body is not valid JSON"),
            ("[1,2]", "Invalid health response: body is not a JSON object"),
            ("\"pass\"", "Invalid health response: body is not a JSON object"),
            ("{}", "Invalid health response: missing \"status\""),
            (#"{"status":"ok"}"#, "Invalid health response: invalid status \"ok\""),
            (#"{"status":1}"#, "Invalid health response: invalid status 1"),
        ]
        for (body, reason) in cases {
            let result = evaluate(200, body)
            XCTAssertFalse(result.isHealthy, body)
            XCTAssertFalse(result.isDegraded, body)
            XCTAssertEqual(result.failureReason, reason, body)
            XCTAssertNil(result.response, body)
        }
    }

    func testReasonComesFromOutput() {
        XCTAssertEqual(evaluate(503, #"{"status":"fail","output":"DB unreachable"}"#).failureReason, "DB unreachable")
        XCTAssertEqual(evaluate(200, #"{"status":"warn","output":"Cache unavailable"}"#).failureReason, "Cache unavailable")
    }

    func testFailKeepsParsedResponse() {
        let result = evaluate(503, #"{"status":"fail","version":"1"}"#)
        XCTAssertEqual(result.response?.status, .fail)
        XCTAssertEqual(result.response?.version, "1")
    }

    func testDeclaredStatusWinsOverLegacyChecks() {
        // A legacy `checks` block is ignored: the monitor trusts the declared overall status.
        let result = evaluate(200, #"{"status":"pass","checks":{"db:x":[{"status":"fail"}]}}"#)
        XCTAssertTrue(result.isHealthy)
        XCTAssertFalse(result.isDegraded)
    }

    func testAssertionsAreANDedOnTopOfPassAndWarn() {
        let assertion = JSONAssertion(path: "serviceId", expectedValue: "billing")
        XCTAssertTrue(evaluate(200, #"{"status":"pass","serviceId":"billing"}"#, assertions: [assertion]).isHealthy)
        let degraded = evaluate(200, #"{"status":"warn","serviceId":"billing"}"#, assertions: [assertion])
        XCTAssertTrue(degraded.isHealthy)
        XCTAssertTrue(degraded.isDegraded)

        let failed = evaluate(200, #"{"status":"warn","serviceId":"search"}"#, assertions: [assertion])
        XCTAssertFalse(failed.isHealthy)
        XCTAssertFalse(failed.isDegraded)
        XCTAssertEqual(failed.failureReason, "\"serviceId\" = search, expected billing")

        let missing = evaluate(200, #"{"status":"pass"}"#, assertions: [assertion])
        XCTAssertEqual(missing.failureReason, "Field \"serviceId\" not found")
    }

    func testFailReasonWinsOverAssertions() {
        let assertion = JSONAssertion(path: "serviceId", expectedValue: "billing")
        let result = evaluate(503, #"{"status":"fail","output":"down","serviceId":"other"}"#, assertions: [assertion])
        XCTAssertEqual(result.failureReason, "down")
    }
}

// MARK: - executeCheck integration (mocked network)

final class HealthStandardExecuteCheckTests: XCTestCase {
    private var session: URLSession!
    private let url = URL(string: "https://example.test/health")!

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

    private func respond(_ status: Int, _ body: String, contentType: String = "application/health+json") {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": contentType])!
            return (response, Data(body.utf8))
        }
    }

    func testStandardEndpointIgnoresExpectedStatusCode() async {
        respond(200, #"{"status":"pass","version":"1.0"}"#)
        let endpoint = Endpoint(name: "API", url: url, expectedStatusCode: 204, healthStandard: true)
        let outcome = await HealthCheckService.executeCheckDetailed(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertTrue(outcome.result.isHealthy)
        XCTAssertFalse(outcome.result.isDegraded)
        XCTAssertEqual(outcome.standardResponse?.version, "1.0")
    }

    func testWarnIsDegradedWithReason() async {
        respond(200, #"{"status":"warn","output":"Queue backlog"}"#)
        let endpoint = Endpoint(name: "API", url: url, healthStandard: true)
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertTrue(result.isHealthy)
        XCTAssertTrue(result.isDegraded)
        XCTAssertEqual(result.failureReason, "Queue backlog")
    }

    func testFailOn503IsDown() async {
        respond(503, #"{"status":"fail","output":"DB unreachable"}"#)
        let endpoint = Endpoint(name: "API", url: url, healthStandard: true)
        let outcome = await HealthCheckService.executeCheckDetailed(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertFalse(outcome.result.isHealthy)
        XCTAssertEqual(outcome.result.statusCode, 503)
        XCTAssertEqual(outcome.result.failureReason, "DB unreachable")
        XCTAssertEqual(outcome.standardResponse?.status, .fail)
    }

    func testNonStandardEndpointKeepsClassicBehaviour() async {
        respond(503, #"{"status":"fail"}"#)
        let endpoint = Endpoint(name: "API", url: url, expectedStatusCode: 503)
        let outcome = await HealthCheckService.executeCheckDetailed(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertTrue(outcome.result.isHealthy)
        XCTAssertFalse(outcome.result.isDegraded)
        XCTAssertNil(outcome.standardResponse)
    }

    func testPerformRequestCapturesContentType() async {
        respond(200, #"{"status":"pass"}"#, contentType: "application/health+json; charset=utf-8")
        guard case .success(let raw) = await HealthCheckService.performRequest(url: url, timeout: 5, session: session) else {
            return XCTFail("request failed")
        }
        XCTAssertEqual(raw.contentType, "application/health+json; charset=utf-8")
    }
}

// MARK: - Overall status, transitions, notification gating, auto version

final class HealthStandardStateTests: XCTestCase {
    private func result(_ healthy: Bool, degraded: Bool = false, reason: String? = nil) -> HealthCheckResult {
        HealthCheckResult(endpointId: UUID(), timestamp: Date(), isHealthy: healthy, responseTimeMs: 1, statusCode: 200,
                          failureReason: reason, isDegraded: degraded)
    }

    func testOverallStatusOrdering() {
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: []), .unknown)
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: [nil, nil]), .unknown)
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: [result(true), nil]), .healthy)
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: [result(true), result(true, degraded: true)]), .degraded)
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: [result(true, degraded: true), result(false)]), .down)
        XCTAssertEqual(HealthCheckService.overallStatus(lastResults: [result(false), result(true)]), .down)
    }

    func testEndpointHealthState() {
        XCTAssertEqual(EndpointHealthState(result(true)), .healthy)
        XCTAssertEqual(EndpointHealthState(result(true, degraded: true)), .degraded)
        XCTAssertEqual(EndpointHealthState(result(false, degraded: true)), .down)
    }

    func testTransitions() {
        let healthy = result(true)
        let degraded = result(true, degraded: true, reason: "Disk")
        let down = result(false, reason: "DB")

        XCTAssertNil(HealthCheckService.healthTransition(previous: nil, current: down))
        XCTAssertNil(HealthCheckService.healthTransition(previous: nil, current: degraded))
        XCTAssertNil(HealthCheckService.healthTransition(previous: healthy, current: healthy))
        XCTAssertNil(HealthCheckService.healthTransition(previous: degraded, current: degraded))
        XCTAssertNil(HealthCheckService.healthTransition(previous: down, current: down))

        XCTAssertEqual(HealthCheckService.healthTransition(previous: healthy, current: down), .down(reason: "DB"))
        XCTAssertEqual(HealthCheckService.healthTransition(previous: degraded, current: down), .down(reason: "DB"))
        XCTAssertEqual(HealthCheckService.healthTransition(previous: down, current: healthy), .recovered(degradedReason: nil))
        XCTAssertEqual(HealthCheckService.healthTransition(previous: down, current: degraded), .recovered(degradedReason: "Disk"))
        XCTAssertEqual(HealthCheckService.healthTransition(previous: healthy, current: degraded), .degraded(reason: "Disk"))
        XCTAssertEqual(HealthCheckService.healthTransition(previous: degraded, current: healthy), .noLongerDegraded)
    }

    func testNotificationGating() {
        let all: [HealthTransition] = [.down(reason: nil), .recovered(degradedReason: nil), .degraded(reason: nil), .noLongerDegraded]
        for transition in all {
            XCTAssertTrue(HealthCheckService.shouldNotify(transition, notificationsEnabled: true, notifyOnRecovery: true, isSnoozed: false))
            XCTAssertFalse(HealthCheckService.shouldNotify(transition, notificationsEnabled: false, notifyOnRecovery: true, isSnoozed: false))
            XCTAssertFalse(HealthCheckService.shouldNotify(transition, notificationsEnabled: true, notifyOnRecovery: true, isSnoozed: true))
        }
        XCTAssertTrue(HealthCheckService.shouldNotify(.down(reason: nil), notificationsEnabled: true, notifyOnRecovery: false, isSnoozed: false))
        XCTAssertTrue(HealthCheckService.shouldNotify(.degraded(reason: nil), notificationsEnabled: true, notifyOnRecovery: false, isSnoozed: false))
        XCTAssertFalse(HealthCheckService.shouldNotify(.recovered(degradedReason: "x"), notificationsEnabled: true, notifyOnRecovery: false, isSnoozed: false))
        XCTAssertFalse(HealthCheckService.shouldNotify(.noLongerDegraded, notificationsEnabled: true, notifyOnRecovery: false, isSnoozed: false))
    }

    func testUsesAutoVersion() {
        let url = URL(string: "https://example.test/health")!
        let config = VersionCheckConfig(url: URL(string: "https://example.test/version")!, versionFieldPath: "v")
        XCTAssertTrue(HealthCheckService.usesAutoVersion(Endpoint(name: "A", url: url, healthStandard: true)))
        var disabled = config
        disabled.isEnabled = false
        XCTAssertTrue(HealthCheckService.usesAutoVersion(Endpoint(name: "A", url: url, versionCheck: disabled, healthStandard: true)))
        XCTAssertFalse(HealthCheckService.usesAutoVersion(Endpoint(name: "A", url: url, versionCheck: config, healthStandard: true)))
        XCTAssertFalse(HealthCheckService.usesAutoVersion(Endpoint(name: "A", url: url)))
        XCTAssertFalse(HealthCheckService.usesAutoVersion(Endpoint(name: "A", url: url, checkType: .tcp, healthStandard: true)))
    }

    /// Auto-tracked values flow through the same `VersionStore.apply` as explicit version checks.
    func testAutoVersionValuesProduceChangeEvents() {
        func record(_ value: String, _ previous: EndpointVersionState?) -> (EndpointVersionState, [VersionCheckEvent]) {
            VersionStore.apply(VersionCheckResult(timestamp: Date(), isSuccess: true, version: value, failureReason: nil,
                                                  responseTimeMs: 1, statusCode: 200), to: previous)
        }
        let first = HealthStandard.trackedVersion(version: "1.0.0", releaseId: "aaaaaaa1")!
        let second = HealthStandard.trackedVersion(version: "1.0.0", releaseId: "bbbbbbb2")!
        let (state, firstEvents) = record(first, nil)
        XCTAssertEqual(firstEvents, [])
        let (_, events) = record(second, state)
        XCTAssertEqual(events, [.changed(from: "1.0.0 (aaaaaaa)", to: "1.0.0 (bbbbbbb)")])
    }
}

// MARK: - Details store

final class HealthDetailsStoreTests: XCTestCase {
    @MainActor
    func testKeepsOnlyLatestPerEndpointAndRemoves() {
        let store = HealthDetailsStore()
        let id = UUID()
        let first = HealthStandardResponse(status: .pass, version: "1", releaseId: nil, output: nil)
        let second = HealthStandardResponse(status: .warn, version: "2", releaseId: nil, output: "x")
        store.record(first, for: id, at: Date(timeIntervalSince1970: 1))
        store.record(second, for: id, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.latest.count, 1)
        XCTAssertEqual(store.details(for: id)?.response, second)
        XCTAssertEqual(store.details(for: id)?.checkedAt, Date(timeIntervalSince1970: 2))
        store.remove(for: id)
        XCTAssertNil(store.details(for: id))
    }
}

// MARK: - Notifications

private final class DegradedRecordingCenter: UserNotificationCentering, @unchecked Sendable {
    private(set) var requests: [UNNotificationRequest] = []
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
}

final class HealthStandardNotificationTests: XCTestCase {
    func testDegradedContent() async {
        let center = DegradedRecordingCenter()
        let service = NotificationService(center: center)
        await service.notifyDegradedAsync(endpointName: "Billing", reason: "Disk usage above 85%")
        await service.notifyNoLongerDegradedAsync(endpointName: "Billing")
        await service.notifyRecoveredAsync(endpointName: "Billing", degradedReason: "Queue backlog")
        await service.notifyRecoveredAsync(endpointName: "Billing")
        XCTAssertEqual(center.requests.map(\.content.title), [
            "Billing degraded", "Billing is healthy again", "Billing is back up, but degraded", "Billing is back up",
        ])
        XCTAssertEqual(center.requests.map(\.content.body), [
            "Disk usage above 85%", "No longer degraded.", "Queue backlog", "Health check succeeded again.",
        ])
    }
}

// MARK: - Backend dashboard decoding

final class DashboardHealthStandardDecodingTests: XCTestCase {
    private func summary(_ json: String) throws -> DashboardSummary {
        try JSONDecoder().decode(DashboardSummary.self, from: Data(json.utf8))
    }

    func testSummaryOverallStatus() throws {
        XCTAssertEqual(try summary(#"{"totalEndpoints":0,"healthyEndpoints":0,"unhealthyEndpoints":0,"pausedEndpoints":0,"overallUptimePercent":100}"#).overallStatus, .unknown)
        XCTAssertEqual(try summary(#"{"totalEndpoints":2,"healthyEndpoints":2,"unhealthyEndpoints":0,"pausedEndpoints":0,"overallUptimePercent":100}"#).overallStatus, .healthy)
        XCTAssertEqual(try summary(#"{"totalEndpoints":2,"healthyEndpoints":2,"unhealthyEndpoints":0,"degradedEndpoints":1,"pausedEndpoints":0,"overallUptimePercent":100}"#).overallStatus, .degraded)
        XCTAssertEqual(try summary(#"{"totalEndpoints":2,"healthyEndpoints":1,"unhealthyEndpoints":1,"degradedEndpoints":1,"pausedEndpoints":0,"overallUptimePercent":50}"#).overallStatus, .down)
    }

    func testLatestCheckHealthState() throws {
        func check(_ extra: String) throws -> LatestCheckInfo {
            try JSONDecoder().decode(LatestCheckInfo.self, from: Data(#"{"isHealthy":true,"responseTimeMs":5,"statusCode":200,"failureReason":null,"timestamp":"2026-10-11T09:30:00Z","certificateExpiresAt":null\#(extra)}"#.utf8))
        }
        XCTAssertEqual(try check("").healthState, .healthy)
        XCTAssertEqual(try check(#","healthStatus":"warn","isDegraded":true"#).healthState, .degraded)
        XCTAssertEqual(try check(#","healthStatus":"pass","isDegraded":false"#).healthState, .healthy)
    }

    func testEndpointDecodesNewOptionalFields() throws {
        let json = #"""
        {"id":"a","name":"API","url":"https://x.test/health","checkType":"http","groupName":null,"isPaused":false,
         "latestCheck":null,"uptimePercent24h":null,"activeIncident":null,
         "version":{"isEnabled":true,"current":"1.0 (abc1234)","isFailing":false,"failureReason":null,"lastCheckedAt":null,"source":"healthStandard"},
         "healthStandard":true,"healthDetails":{"status":"pass","components":[]}}
        """#
        let endpoint = try JSONDecoder().decode(DashboardEndpointInfo.self, from: Data(json.utf8))
        XCTAssertEqual(endpoint.healthStandard, true)
        XCTAssertEqual(endpoint.version?.source, "healthStandard")
    }
}
