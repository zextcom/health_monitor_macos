import XCTest
@testable import ProjeHealthMonitor

// MARK: - Widget

final class WidgetDegradedTests: XCTestCase {
    private func status(_ name: String, healthy: Bool, degraded: Bool = false) -> WidgetEndpointStatus {
        WidgetEndpointStatus(name: name, url: "https://\(name).test", isHealthy: healthy, isDegraded: degraded,
                             responseTimeMs: nil, lastCheckedAt: nil, group: nil)
    }

    func testEndpointStateFromFlags() {
        XCTAssertEqual(status("a", healthy: true).state, .healthy)
        XCTAssertEqual(status("a", healthy: true, degraded: true).state, .degraded)
        XCTAssertEqual(status("a", healthy: false).state, .down)
        XCTAssertEqual(status("a", healthy: false, degraded: true).state, .down, "down wins over a stale degraded flag")
    }

    func testStateSymbolsMatchTheApp() {
        XCTAssertEqual(WidgetHealthState.healthy.symbolName, EndpointHealthState.healthy.symbolName)
        XCTAssertEqual(WidgetHealthState.degraded.symbolName, EndpointHealthState.degraded.symbolName)
        XCTAssertEqual(WidgetHealthState.down.symbolName, EndpointHealthState.down.symbolName)
    }

    func testSummaryAllHealthy() {
        let summary = WidgetSummary(endpoints: [status("a", healthy: true), status("b", healthy: true)])
        XCTAssertEqual(summary.overallState, .healthy)
        XCTAssertEqual(summary.headline, "2/2 Healthy")
    }

    func testSummaryDegradedOnly() {
        let summary = WidgetSummary(endpoints: [status("a", healthy: true), status("b", healthy: true, degraded: true),
                                                status("c", healthy: true)])
        XCTAssertEqual(summary.overallState, .degraded)
        XCTAssertEqual(summary.headline, "1/3 Degraded")
    }

    func testSummaryDownBeatsDegraded() {
        let downOnly = WidgetSummary(endpoints: [status("a", healthy: false), status("b", healthy: true)])
        XCTAssertEqual(downOnly.overallState, .down)
        XCTAssertEqual(downOnly.headline, "1/2 Down")

        let mixed = WidgetSummary(endpoints: [status("a", healthy: false), status("b", healthy: true, degraded: true),
                                              status("c", healthy: true)])
        XCTAssertEqual(mixed.overallState, .down)
        XCTAssertEqual(mixed.headline, "1/3 Down · 1 Degraded")
        XCTAssertEqual([mixed.healthy, mixed.degraded, mixed.down], [1, 1, 1])
    }

    func testSnapshotFromOlderAppDecodesAsNotDegraded() throws {
        let json = #"{"name":"API","url":"https://api.test","isHealthy":true,"responseTimeMs":42,"group":null}"#
        let decoded = try JSONDecoder().decode(WidgetEndpointStatus.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isDegraded)
        XCTAssertEqual(decoded.state, .healthy)
    }

    func testDegradedFlagRoundTrips() throws {
        let original = status("logs", healthy: true, degraded: true)
        let decoded = try JSONDecoder().decode(WidgetEndpointStatus.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.isDegraded)
    }
}

// MARK: - Status page

final class StatusPageDegradedTests: XCTestCase {
    private func summary(_ name: String, healthy: Bool?, degraded: Bool = false) -> HealthCheckService.EndpointStatusSummary {
        HealthCheckService.EndpointStatusSummary(name: name, group: nil, isHealthy: healthy, isDegraded: degraded,
                                                 uptimePercentage: 99, lastCheckedAt: Date(timeIntervalSince1970: 0),
                                                 isSnoozed: false)
    }

    func testSummaryState() {
        XCTAssertEqual(summary("a", healthy: true).state, .healthy)
        XCTAssertEqual(summary("a", healthy: true, degraded: true).state, .degraded)
        XCTAssertEqual(summary("a", healthy: false, degraded: true).state, .down)
        XCTAssertNil(summary("a", healthy: nil).state)
    }

    func testSummaryLineExcludesDegradedFromHealthyAndMentionsThem() {
        let line = HealthCheckService.statusPageSummaryLine([
            summary("a", healthy: true), summary("b", healthy: true, degraded: true),
            summary("c", healthy: false), summary("d", healthy: nil),
        ])
        XCTAssertEqual(line, "1 of 4 endpoints healthy · 1 degraded")
    }

    func testSummaryLineWithoutDegradedIsUnchanged() {
        XCTAssertEqual(HealthCheckService.statusPageSummaryLine([summary("a", healthy: true), summary("b", healthy: false)]),
                       "1 of 2 endpoints healthy")
    }

    func testHTMLRendersDegradedRowWithDistinctClass() {
        let html = HealthCheckService.statusPageHTML(summaries: [summary("Logs", healthy: true, degraded: true)],
                                                     generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(html.contains("class=\"dot degraded\""))
        XCTAssertTrue(html.contains("Degraded · 99.0% uptime"))
        XCTAssertTrue(html.contains(".dot.degraded {"), "degraded needs its own style")
        XCTAssertFalse(html.contains("class=\"dot healthy\""))
    }

    func testJSONIncludesDegradedFlag() throws {
        let data = HealthCheckService.statusPageJSON(summaries: [summary("Logs", healthy: true, degraded: true),
                                                                 summary("API", healthy: true)],
                                                     generatedAt: Date(timeIntervalSince1970: 0))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let endpoints = try XCTUnwrap(object?["endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.map { $0["isDegraded"] as? Bool }, [true, false])
    }
}
