import XCTest
import Network
import Security
@testable import ProjeHealthMonitor

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Mirrors the shape `HealthCheckService.statusPageJSON` encodes (its own payload wrapper is
/// private) so tests can decode and assert on the real output rather than reaching into internals.
private struct StatusPageDecodedPayload: Decodable {
    struct Endpoint: Decodable {
        let name: String
        let group: String?
        let isHealthy: Bool?
        let uptimePercentage: Double?
        let lastCheckedAt: Date?
        let isSnoozed: Bool
    }
    let generatedAt: Date
    let endpoints: [Endpoint]
}

final class HealthCheckServiceTests: XCTestCase {
    private var session: URLSession!

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

    private func makeEndpoint(
        expectedStatusCode: Int = 200,
        jsonAssertions: [JSONAssertion] = []
    ) -> Endpoint {
        Endpoint(
            name: "Test",
            url: URL(string: "https://example.test/health")!,
            expectedStatusCode: expectedStatusCode,
            jsonAssertions: jsonAssertions
        )
    }

    func testHealthyWhenStatusCodeMatches() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let result = await HealthCheckService.executeCheck(endpoint: makeEndpoint(), timeout: 5, session: session)
        XCTAssertTrue(result.isHealthy)
        XCTAssertEqual(result.statusCode, 200)
    }

    func testDownWhenStatusCodeMismatches() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let result = await HealthCheckService.executeCheck(endpoint: makeEndpoint(), timeout: 5, session: session)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.statusCode, 500)
    }

    func testHealthyWhenNestedJsonFieldMatches() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"success":true,"data":{"status":"healthy","database":true}}"#
            return (response, Data(body.utf8))
        }
        let endpoint = makeEndpoint(jsonAssertions: [JSONAssertion(path: "data.status", expectedValue: "healthy")])
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertTrue(result.isHealthy)
    }

    func testDownWhenNestedJsonFieldMismatches() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"success":true,"data":{"status":"degraded"}}"#
            return (response, Data(body.utf8))
        }
        let endpoint = makeEndpoint(jsonAssertions: [JSONAssertion(path: "data.status", expectedValue: "healthy")])
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertFalse(result.isHealthy)
        XCTAssertNotNil(result.failureReason)
    }

    func testHealthyWhenAllAssertionsMatch() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"data":{"status":"healthy","database":true}}"#
            return (response, Data(body.utf8))
        }
        let endpoint = makeEndpoint(jsonAssertions: [
            JSONAssertion(path: "data.status", expectedValue: "healthy"),
            JSONAssertion(path: "data.database", expectedValue: "true"),
        ])
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertTrue(result.isHealthy)
    }

    func testDownWhenSecondAssertionFails() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"data":{"status":"healthy","database":false}}"#
            return (response, Data(body.utf8))
        }
        let endpoint = makeEndpoint(jsonAssertions: [
            JSONAssertion(path: "data.status", expectedValue: "healthy"),
            JSONAssertion(path: "data.database", expectedValue: "true"),
        ])
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, session: session)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.failureReason, "\"data.database\" = false, expected true")
    }

    func testHealthyWithEmptyAssertionListChecksStatusCodeOnly() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json at all".utf8))
        }
        let result = await HealthCheckService.executeCheck(endpoint: makeEndpoint(), timeout: 5, session: session)
        XCTAssertTrue(result.isHealthy)
    }

    // MARK: - evaluateAssertions (pure)

    func testEvaluateAssertionsPassesWhenAllMatch() {
        let json: Any = ["data": ["status": "healthy", "database": true]]
        let assertions = [
            JSONAssertion(path: "data.status", expectedValue: "healthy"),
            JSONAssertion(path: "data.database", expectedValue: "true"),
        ]
        let (passed, reason) = HealthCheckService.evaluateAssertions(json: json, assertions: assertions)
        XCTAssertTrue(passed)
        XCTAssertNil(reason)
    }

    func testEvaluateAssertionsFailsOnMissingField() {
        let json: Any = ["data": ["status": "healthy"]]
        let assertions = [JSONAssertion(path: "data.missing", expectedValue: "x")]
        let (passed, reason) = HealthCheckService.evaluateAssertions(json: json, assertions: assertions)
        XCTAssertFalse(passed)
        XCTAssertEqual(reason, "Field \"data.missing\" not found")
    }

    func testEvaluateAssertionsWithEmptyListPasses() {
        let (passed, reason) = HealthCheckService.evaluateAssertions(json: ["a": "b"], assertions: [])
        XCTAssertTrue(passed)
        XCTAssertNil(reason)
    }

    // MARK: - Legacy single-assertion schema migration

    func testDecodingLegacySchemaMigratesToSingleAssertion() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200,
            "jsonFieldPath": "data.status",
            "expectedFieldValue": "healthy"
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(endpoint.jsonAssertions.count, 1)
        XCTAssertEqual(endpoint.jsonAssertions.first?.path, "data.status")
        XCTAssertEqual(endpoint.jsonAssertions.first?.expectedValue, "healthy")
    }

    func testDecodingLegacySchemaWithoutJsonFieldsYieldsEmptyAssertions() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(endpoint.jsonAssertions.isEmpty)
    }

    func testEncodingRoundTripsThroughNewSchema() throws {
        var endpoint = makeEndpoint(jsonAssertions: [JSONAssertion(path: "data.status", expectedValue: "healthy")])
        endpoint.name = "Round Trip"
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertEqual(decoded.jsonAssertions, endpoint.jsonAssertions)
        XCTAssertEqual(decoded.name, "Round Trip")
    }

    // MARK: - checkType / matchMode backward compatibility

    func testDecodingEndpointWithoutCheckTypeDefaultsToHTTP() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(endpoint.checkType, .http)
    }

    func testEncodingRoundTripsCheckTypeTCP() throws {
        var endpoint = makeEndpoint()
        endpoint.checkType = .tcp
        endpoint.url = URL(string: "tcp://db.example.test:5432")!
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertEqual(decoded.checkType, .tcp)
        XCTAssertEqual(decoded.url.host, "db.example.test")
        XCTAssertEqual(decoded.url.port, 5432)
    }

    func testDecodingJSONAssertionWithoutMatchModeDefaultsToExact() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200,
            "jsonAssertions": [
                { "id": "22222222-2222-2222-2222-222222222222", "path": "data.status", "expectedValue": "healthy" }
            ]
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(endpoint.jsonAssertions.first?.matchMode, .exact)
    }

    func testEncodingRoundTripsMatchMode() throws {
        var endpoint = makeEndpoint(jsonAssertions: [JSONAssertion(path: "data.status", expectedValue: "health", matchMode: .contains)])
        endpoint.name = "Round Trip Match Mode"
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertEqual(decoded.jsonAssertions.first?.matchMode, .contains)
    }

    // MARK: - group / snoozedUntil backward compatibility

    func testDecodingEndpointWithoutGroupDefaultsToNil() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(endpoint.group)
    }

    func testEncodingRoundTripsGroup() throws {
        var endpoint = makeEndpoint()
        endpoint.group = "Production"
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertEqual(decoded.group, "Production")
    }

    func testDecodingEndpointWithoutSnoozedUntilDefaultsToNil() throws {
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "url": "https://example.test/health",
            "expectedStatusCode": 200
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(endpoint.snoozedUntil)
    }

    func testEncodingRoundTripsSnoozedUntil() throws {
        var endpoint = makeEndpoint()
        endpoint.snoozedUntil = Date(timeIntervalSince1970: 1_000_000)
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)
        XCTAssertEqual(decoded.snoozedUntil, endpoint.snoozedUntil)
    }

    func testDownOnNetworkTimeout() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let result = await HealthCheckService.executeCheck(endpoint: makeEndpoint(), timeout: 5, session: session)
        XCTAssertFalse(result.isHealthy)
        XCTAssertNil(result.statusCode)
    }

    func testExtractValueResolvesNestedBoolAsString() {
        let json: Any = ["data": ["database": true, "status": "healthy"]]
        XCTAssertEqual(HealthCheckService.extractValue(from: json, path: "data.status"), "healthy")
        XCTAssertEqual(HealthCheckService.extractValue(from: json, path: "data.database"), "true")
        XCTAssertNil(HealthCheckService.extractValue(from: json, path: "data.missing"))
    }

    func testPerformRequestReturnsRawStatusAndBody() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"healthy"}"#.utf8))
        }
        let result = await HealthCheckService.performRequest(url: URL(string: "https://example.test/health")!, timeout: 5, session: session)
        switch result {
        case .success(let raw):
            XCTAssertEqual(raw.statusCode, 200)
            XCTAssertEqual(String(data: raw.data, encoding: .utf8), #"{"status":"healthy"}"#)
        case .failure:
            XCTFail("Expected success")
        }
    }

    func testPerformRequestReportsTimeout() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let result = await HealthCheckService.performRequest(url: URL(string: "https://example.test/health")!, timeout: 5, session: session)
        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure(let error):
            if case .timedOut = error {
                // expected
            } else {
                XCTFail("Expected .timedOut, got \(error)")
            }
        }
    }

    func testFlattenProducesSortedSelectablePaths() {
        let json: Any = [
            "success": true,
            "data": ["status": "healthy", "tags": ["a", "b"]]
        ]
        let fields = HealthCheckService.flatten(json: json)
        let byPath = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })

        XCTAssertEqual(byPath["success"]?.value, "true")
        XCTAssertTrue(byPath["success"]?.isSelectable ?? false)

        XCTAssertEqual(byPath["data.status"]?.value, "healthy")
        XCTAssertTrue(byPath["data.status"]?.isSelectable ?? false)

        XCTAssertEqual(byPath["data.tags"]?.value, "[array]")
        XCTAssertFalse(byPath["data.tags"]?.isSelectable ?? true)

        XCTAssertEqual(fields.map(\.path), fields.map(\.path).sorted())
    }

    func testEvaluateIsTrimmedAndCaseInsensitive() {
        XCTAssertTrue(HealthCheckService.evaluate(actualValue: " Healthy ", expectedValue: "healthy"))
        XCTAssertFalse(HealthCheckService.evaluate(actualValue: "degraded", expectedValue: "healthy"))
    }

    func testEvaluateContainsModeMatchesSubstringCaseInsensitively() {
        XCTAssertTrue(HealthCheckService.evaluate(actualValue: "all systems Healthy", expectedValue: "healthy", mode: .contains))
        XCTAssertFalse(HealthCheckService.evaluate(actualValue: "degraded", expectedValue: "healthy", mode: .contains))
    }

    func testEvaluateRegexModeMatchesPattern() {
        XCTAssertTrue(HealthCheckService.evaluate(actualValue: "v1.2.3", expectedValue: #"^v\d+\.\d+\.\d+$"#, mode: .regex))
        XCTAssertFalse(HealthCheckService.evaluate(actualValue: "not-a-version", expectedValue: #"^v\d+\.\d+\.\d+$"#, mode: .regex))
    }

    func testEvaluateRegexModeWithInvalidPatternReturnsFalseInsteadOfThrowing() {
        XCTAssertFalse(HealthCheckService.evaluate(actualValue: "anything", expectedValue: "([unclosed", mode: .regex))
    }

    // MARK: - Uptime percentage

    private func makeResult(isHealthy: Bool) -> HealthCheckResult {
        HealthCheckResult(endpointId: UUID(), timestamp: Date(), isHealthy: isHealthy,
                           responseTimeMs: 50, statusCode: 200, failureReason: nil)
    }

    func testUptimePercentageIsNilForEmptyHistory() {
        XCTAssertNil(HealthCheckService.uptimePercentage(results: []))
    }

    func testUptimePercentageComputesRatio() {
        let results = [makeResult(isHealthy: true), makeResult(isHealthy: true),
                        makeResult(isHealthy: true), makeResult(isHealthy: false)]
        XCTAssertEqual(HealthCheckService.uptimePercentage(results: results) ?? -1, 75.0, accuracy: 0.001)
    }

    func testUptimePercentageIsHundredWhenAllHealthy() {
        let results = [makeResult(isHealthy: true), makeResult(isHealthy: true)]
        XCTAssertEqual(HealthCheckService.uptimePercentage(results: results) ?? -1, 100.0, accuracy: 0.001)
    }

    // MARK: - Incidents

    private func makeIncidentResult(isHealthy: Bool, secondsFromEpoch: TimeInterval, failureReason: String? = nil) -> HealthCheckResult {
        HealthCheckResult(endpointId: UUID(), timestamp: Date(timeIntervalSince1970: secondsFromEpoch),
                           isHealthy: isHealthy, responseTimeMs: 50, statusCode: isHealthy ? 200 : 500,
                           failureReason: failureReason)
    }

    func testIncidentsIsEmptyWhenAllHealthy() {
        let results = [makeIncidentResult(isHealthy: true, secondsFromEpoch: 0),
                        makeIncidentResult(isHealthy: true, secondsFromEpoch: 60)]
        XCTAssertEqual(HealthCheckService.incidents(from: results), [])
    }

    func testIncidentsIsEmptyForEmptyInput() {
        XCTAssertEqual(HealthCheckService.incidents(from: []), [])
    }

    func testIncidentsClosesRunOnRecovery() {
        let results = [
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 0),
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 60, failureReason: "Timed out"),
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 120, failureReason: "Timed out"),
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 180),
        ]
        let incidents = HealthCheckService.incidents(from: results)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents[0].startedAt, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(incidents[0].endedAt, Date(timeIntervalSince1970: 180))
        XCTAssertEqual(incidents[0].failureReason, "Timed out")
        XCTAssertFalse(incidents[0].startBoundaryUncertain)
    }

    func testIncidentsLeavesRunOpenWhenStillDownAtEndOfHistory() {
        let results = [
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 0),
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 60, failureReason: "Connection refused"),
        ]
        let incidents = HealthCheckService.incidents(from: results)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertNil(incidents[0].endedAt)
    }

    func testIncidentsFlagsUncertainStartWhenFirstResultIsAlreadyDown() {
        let results = [
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 0, failureReason: "Timed out"),
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 60),
        ]
        let incidents = HealthCheckService.incidents(from: results)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertTrue(incidents[0].startBoundaryUncertain)
    }

    func testIncidentsDetectsMultipleSeparateRuns() {
        let results = [
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 0),
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 60),
            makeIncidentResult(isHealthy: false, secondsFromEpoch: 120),
            makeIncidentResult(isHealthy: true, secondsFromEpoch: 180),
        ]
        XCTAssertEqual(HealthCheckService.incidents(from: results).count, 2)
    }

    // MARK: - CSV export

    func testCSVIncludesHeaderRow() {
        XCTAssertEqual(HealthCheckService.csv(for: [], endpointName: "API").split(separator: "\n").first,
                        "endpoint,timestamp,isHealthy,responseTimeMs,statusCode,failureReason")
    }

    func testCSVEscapesFailureReasonContainingComma() {
        let result = makeIncidentResult(isHealthy: false, secondsFromEpoch: 0, failureReason: "Expected 200, got 500")
        let csv = HealthCheckService.csv(for: [result], endpointName: "API")
        XCTAssertTrue(csv.contains("\"Expected 200, got 500\""))
    }

    func testCSVEscapesFailureReasonContainingQuote() {
        let result = makeIncidentResult(isHealthy: false, secondsFromEpoch: 0, failureReason: "field \"status\" mismatch")
        let csv = HealthCheckService.csv(for: [result], endpointName: "API")
        XCTAssertTrue(csv.contains("\"field \"\"status\"\" mismatch\""))
    }

    func testCSVOmitsFailureReasonQuotingWhenPlainText() {
        let result = makeIncidentResult(isHealthy: true, secondsFromEpoch: 0)
        let csv = HealthCheckService.csv(for: [result], endpointName: "API")
        let dataRow = csv.split(separator: "\n").last!
        XCTAssertFalse(dataRow.contains("\""))
    }

    // MARK: - Status page export

    private func makeSummary(
        name: String = "API",
        group: String? = nil,
        isHealthy: Bool? = true,
        uptimePercentage: Double? = 99.5,
        lastCheckedAt: Date? = Date(timeIntervalSince1970: 0),
        isSnoozed: Bool = false
    ) -> HealthCheckService.EndpointStatusSummary {
        HealthCheckService.EndpointStatusSummary(
            name: name, group: group, isHealthy: isHealthy, uptimePercentage: uptimePercentage,
            lastCheckedAt: lastCheckedAt, isSnoozed: isSnoozed)
    }

    func testStatusPageHTMLEscapesFreeTextFields() {
        let summary = makeSummary(name: "<script>alert(1)</script> & \"Co\"", group: "R&D <ops>")
        let html = HealthCheckService.statusPageHTML(summaries: [summary], generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;Co&quot;"))
        XCTAssertTrue(html.contains("R&amp;D &lt;ops&gt;"))
    }

    func testStatusPageHTMLSummaryLineReflectsHealthyCount() {
        let summaries = [
            makeSummary(name: "A", isHealthy: true),
            makeSummary(name: "B", isHealthy: true),
            makeSummary(name: "C", isHealthy: false),
            makeSummary(name: "D", isHealthy: nil),
        ]
        let html = HealthCheckService.statusPageHTML(summaries: summaries, generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(html.contains("2 of 4 endpoints healthy"))
    }

    func testStatusPageHTMLMarksSnoozedEndpoint() {
        let summary = makeSummary(name: "Maintenance API", isSnoozed: true)
        let html = HealthCheckService.statusPageHTML(summaries: [summary], generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(html.contains("Snoozed"))
    }

    func testStatusPageHTMLRendersEndpointWithNoHistoryWithoutCrashing() {
        let summary = makeSummary(name: "Never Checked", isHealthy: nil, uptimePercentage: nil, lastCheckedAt: nil)
        let html = HealthCheckService.statusPageHTML(summaries: [summary], generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(html.contains("Never Checked"))
        XCTAssertTrue(html.contains("No data yet"))
        XCTAssertTrue(html.contains("No uptime data"))
        XCTAssertTrue(html.contains("Never checked"))
    }

    func testStatusPageHTMLHandlesEmptySummaryList() {
        let html = HealthCheckService.statusPageHTML(summaries: [], generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(html.contains("0 of 0 endpoints healthy"))
    }

    func testStatusPageJSONRoundTripsFields() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let summaries = [
            makeSummary(name: "API", group: "Production", isHealthy: true, uptimePercentage: 99.9,
                        lastCheckedAt: Date(timeIntervalSince1970: 1_699_999_000), isSnoozed: false),
            makeSummary(name: "Worker", group: nil, isHealthy: nil, uptimePercentage: nil,
                        lastCheckedAt: nil, isSnoozed: true),
        ]
        let data = HealthCheckService.statusPageJSON(summaries: summaries, generatedAt: generatedAt)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StatusPageDecodedPayload.self, from: data)

        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970, generatedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.endpoints.count, 2)

        XCTAssertEqual(decoded.endpoints[0].name, "API")
        XCTAssertEqual(decoded.endpoints[0].group, "Production")
        XCTAssertEqual(decoded.endpoints[0].isHealthy, true)
        XCTAssertEqual(decoded.endpoints[0].uptimePercentage ?? -1, 99.9, accuracy: 0.001)
        XCTAssertNotNil(decoded.endpoints[0].lastCheckedAt)
        XCTAssertEqual(decoded.endpoints[0].isSnoozed, false)

        XCTAssertEqual(decoded.endpoints[1].name, "Worker")
        XCTAssertNil(decoded.endpoints[1].group)
        XCTAssertNil(decoded.endpoints[1].isHealthy)
        XCTAssertNil(decoded.endpoints[1].uptimePercentage)
        XCTAssertNil(decoded.endpoints[1].lastCheckedAt)
        XCTAssertEqual(decoded.endpoints[1].isSnoozed, true)
    }

    // MARK: - TLS certificate expiry (pure threshold logic; the network fetch itself isn't mockable)

    func testDaysUntilExpiryRoundsDownToWholeDays() {
        let now = Date(timeIntervalSince1970: 0)
        let in10Days = now.addingTimeInterval(10 * 86400 + 3600) // 10 days + 1 hour
        XCTAssertEqual(HealthCheckService.daysUntilExpiry(in10Days, from: now), 10)

        let expired = now.addingTimeInterval(-5 * 86400)
        XCTAssertEqual(HealthCheckService.daysUntilExpiry(expired, from: now), -5)
    }

    func testIsExpiringSoonRespectsThreshold() {
        let now = Date(timeIntervalSince1970: 0)
        let in5Days = now.addingTimeInterval(5 * 86400)
        let in30Days = now.addingTimeInterval(30 * 86400)

        XCTAssertTrue(HealthCheckService.isExpiringSoon(in5Days, thresholdDays: 14, now: now))
        XCTAssertFalse(HealthCheckService.isExpiringSoon(in30Days, thresholdDays: 14, now: now))
        XCTAssertFalse(HealthCheckService.isExpiringSoon(nil, thresholdDays: 14, now: now))
    }

    // MARK: - Retained-deleted-endpoint expiry (pure threshold logic; the sweep itself isn't unit-tested, see HealthCheckService)

    func testIsRetainedRecordExpiredTrueAfterRetentionWindow() {
        let now = Date(timeIntervalSince1970: 0)
        let deletedAt = now.addingTimeInterval(-31 * 86400)
        XCTAssertTrue(HealthCheckService.isRetainedRecordExpired(deletedAt: deletedAt, retentionDays: 30, now: now))
    }

    func testIsRetainedRecordExpiredFalseWithinRetentionWindow() {
        let now = Date(timeIntervalSince1970: 0)
        let deletedAt = now.addingTimeInterval(-29 * 86400)
        XCTAssertFalse(HealthCheckService.isRetainedRecordExpired(deletedAt: deletedAt, retentionDays: 30, now: now))
    }

    // MARK: - Snooze (pure gate logic; performCheck's notification suppression itself isn't unit-tested)

    func testIsSnoozedTrueWhenSnoozedUntilIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 0)
        var endpoint = makeEndpoint()
        endpoint.snoozedUntil = now.addingTimeInterval(30 * 60)
        XCTAssertTrue(HealthCheckService.isSnoozed(endpoint, now: now))
    }

    func testIsSnoozedFalseWhenSnoozedUntilIsInThePast() {
        let now = Date(timeIntervalSince1970: 0)
        var endpoint = makeEndpoint()
        endpoint.snoozedUntil = now.addingTimeInterval(-30 * 60)
        XCTAssertFalse(HealthCheckService.isSnoozed(endpoint, now: now))
    }

    func testIsSnoozedFalseWhenSnoozedUntilIsNil() {
        let now = Date(timeIntervalSince1970: 0)
        let endpoint = makeEndpoint()
        XCTAssertFalse(HealthCheckService.isSnoozed(endpoint, now: now))
    }

    func testNotAfterDateParsesKnownCertificateExpiry() throws {
        let derData = Data(base64Encoded: CertificateFixtures.leafCertificateDERBase64.replacingOccurrences(of: "\n", with: ""))!
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, derData as CFData))
        let expiry = try XCTUnwrap(HealthCheckService.notAfterDate(from: certificate))
        XCTAssertEqual(expiry.timeIntervalSince1970,
                        CertificateFixtures.leafCertificateExpiry.timeIntervalSince1970,
                        accuracy: 2)
    }

    // MARK: - Auth headers

    func testAuthHeadersNoneReturnsEmpty() {
        XCTAssertTrue(HealthCheckService.authHeaders(type: .none, username: nil, secret: "whatever", headerName: nil).isEmpty)
    }

    func testAuthHeadersWithoutSecretReturnsEmpty() {
        XCTAssertTrue(HealthCheckService.authHeaders(type: .bearerToken, username: nil, secret: nil, headerName: nil).isEmpty)
        XCTAssertTrue(HealthCheckService.authHeaders(type: .bearerToken, username: nil, secret: "", headerName: nil).isEmpty)
    }

    func testAuthHeadersBearerToken() {
        let headers = HealthCheckService.authHeaders(type: .bearerToken, username: nil, secret: "abc123", headerName: nil)
        XCTAssertEqual(headers["Authorization"], "Bearer abc123")
    }

    func testAuthHeadersBasicAuthEncodesCredentials() {
        let headers = HealthCheckService.authHeaders(type: .basicAuth, username: "alice", secret: "s3cret", headerName: nil)
        let expected = "Basic " + Data("alice:s3cret".utf8).base64EncodedString()
        XCTAssertEqual(headers["Authorization"], expected)
    }

    func testAuthHeadersCustomHeaderUsesGivenName() {
        let headers = HealthCheckService.authHeaders(type: .customHeader, username: nil, secret: "key-value", headerName: "X-API-Key")
        XCTAssertEqual(headers["X-API-Key"], "key-value")
    }

    func testAuthHeadersCustomHeaderWithoutNameReturnsEmpty() {
        let headers = HealthCheckService.authHeaders(type: .customHeader, username: nil, secret: "key-value", headerName: nil)
        XCTAssertTrue(headers.isEmpty)
    }

    func testPerformRequestSendsProvidedHeaders() async {
        var receivedHeaders: [String: String]?
        MockURLProtocol.requestHandler = { request in
            receivedHeaders = request.allHTTPHeaderFields
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        _ = await HealthCheckService.performRequest(
            url: URL(string: "https://example.test/health")!, timeout: 5,
            headers: ["Authorization": "Bearer abc123"], session: session)
        XCTAssertEqual(receivedHeaders?["Authorization"], "Bearer abc123")
    }

    func testExecuteCheckSendsAuthHeaderFromSecretParameter() async {
        var receivedHeaders: [String: String]?
        MockURLProtocol.requestHandler = { request in
            receivedHeaders = request.allHTTPHeaderFields
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        var endpoint = makeEndpoint()
        endpoint.authType = .bearerToken
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, secret: "tok-1", session: session)
        XCTAssertTrue(result.isHealthy)
        XCTAssertEqual(receivedHeaders?["Authorization"], "Bearer tok-1")
    }

    // MARK: - TCP checks

    /// Single-resume guard for `waitUntilReady`, mirroring the pattern `HealthCheckService`'s own
    /// `NWConnection`/`NWListener` continuations use.
    private final class ListenerResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<UInt16, Never>

        init(continuation: CheckedContinuation<UInt16, Never>) {
            self.continuation = continuation
        }

        func resumeOnce(_ port: UInt16) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: port)
        }
    }

    /// Starts a local TCP listener on an OS-assigned ephemeral port and returns it once ready, so
    /// TCP-check tests don't depend on any real external host being reachable from CI.
    private func startEphemeralListener() async -> (listener: NWListener, port: UInt16) {
        let listener = try! NWListener(using: .tcp)
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumer = ListenerResumer(continuation: continuation)
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    resumer.resumeOnce(port.rawValue)
                }
            }
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.start(queue: .main)
        }
        return (listener, port)
    }

    func testExecuteCheckTCPHealthyOnSuccessfulConnect() async {
        let (listener, port) = await startEphemeralListener()
        defer { listener.cancel() }

        let endpoint = Endpoint(name: "TCP Test", url: URL(string: "tcp://127.0.0.1:\(port)")!, checkType: .tcp)
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5)

        XCTAssertTrue(result.isHealthy)
        XCTAssertNil(result.statusCode)
        XCTAssertNotNil(result.responseTimeMs)
        XCTAssertNil(result.failureReason)
    }

    func testExecuteCheckTCPDownWhenConnectionRefused() async throws {
        let (listener, port) = await startEphemeralListener()
        listener.cancel()
        try await Task.sleep(nanoseconds: 200_000_000) // let the OS actually release the port

        // Short timeout: NWConnection retries a refused loopback connection internally for
        // several seconds before surfacing `.failed`, so this exercises our own timeout path
        // rather than waiting that out — still a legitimate down/failureReason outcome either way.
        let endpoint = Endpoint(name: "TCP Test", url: URL(string: "tcp://127.0.0.1:\(port)")!, checkType: .tcp)
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 1)

        XCTAssertFalse(result.isHealthy)
        XCTAssertNil(result.statusCode)
        XCTAssertNotNil(result.failureReason)
    }

    func testExecuteCheckTCPIgnoresJSONAssertionsAndAuth() async {
        let (listener, port) = await startEphemeralListener()
        defer { listener.cancel() }

        // Configured so an HTTP-style evaluation would fail — TCP checks must ignore both entirely.
        let endpoint = Endpoint(name: "TCP Test", url: URL(string: "tcp://127.0.0.1:\(port)")!, checkType: .tcp,
                                 jsonAssertions: [JSONAssertion(path: "nonexistent", expectedValue: "wontmatch")],
                                 authType: .bearerToken)
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5, secret: "irrelevant")

        XCTAssertTrue(result.isHealthy)
    }

    func testExecuteCheckTCPFailsWithoutPort() async {
        let endpoint = Endpoint(name: "TCP Test", url: URL(string: "tcp://127.0.0.1")!, checkType: .tcp)
        let result = await HealthCheckService.executeCheck(endpoint: endpoint, timeout: 5)

        XCTAssertFalse(result.isHealthy)
        XCTAssertNotNil(result.failureReason)
    }
}

final class SecretStoreTests: XCTestCase {
    func testSetSecretThenReadReturnsSameValue() {
        let id = UUID().uuidString
        defer { SecretStore.deleteSecret(for: id) }
        SecretStore.setSecret("hunter2", for: id)
        XCTAssertEqual(SecretStore.secret(for: id), "hunter2")
    }

    func testSecretForUnknownIdIsNil() {
        XCTAssertNil(SecretStore.secret(for: UUID().uuidString))
    }

    func testDeleteSecretRemovesIt() {
        let id = UUID().uuidString
        SecretStore.setSecret("temp", for: id)
        XCTAssertNotNil(SecretStore.secret(for: id))
        SecretStore.deleteSecret(for: id)
        XCTAssertNil(SecretStore.secret(for: id))
    }

    func testSetSecretOverwritesPreviousValue() {
        let id = UUID().uuidString
        defer { SecretStore.deleteSecret(for: id) }
        SecretStore.setSecret("first", for: id)
        SecretStore.setSecret("second", for: id)
        XCTAssertEqual(SecretStore.secret(for: id), "second")
    }

    func testSetEmptySecretClearsIt() {
        let id = UUID().uuidString
        SecretStore.setSecret("first", for: id)
        SecretStore.setSecret("", for: id)
        XCTAssertNil(SecretStore.secret(for: id))
    }

    func testNonUUIDAccountKeyWorks() {
        let account = "arbitrary-account-key"
        defer { SecretStore.deleteSecret(for: account) }
        SecretStore.setSecret("ghp_faketoken", for: account)
        XCTAssertEqual(SecretStore.secret(for: account), "ghp_faketoken")
    }
}
