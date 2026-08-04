import XCTest
@testable import ProjeHealthMonitor

final class HealthHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthHistoryStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        super.tearDown()
    }

    private func makeResult(endpointId: UUID, isHealthy: Bool, secondsAgo: TimeInterval = 0) -> HealthCheckResult {
        HealthCheckResult(endpointId: endpointId, timestamp: Date().addingTimeInterval(-secondsAgo),
                           isHealthy: isHealthy, responseTimeMs: 100, statusCode: 200, failureReason: nil)
    }

    @MainActor func testRecordAppendsAndLastResultReturnsMostRecent() {
        let store = HealthHistoryStore(fileURL: fileURL)
        let endpointId = UUID()

        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 10))
        store.record(makeResult(endpointId: endpointId, isHealthy: false, secondsAgo: 0))

        XCTAssertEqual(store.results(for: endpointId).count, 2)
        XCTAssertEqual(store.lastResult(for: endpointId)?.isHealthy, false)
    }

    @MainActor func testLastResultIsNilForUnknownEndpoint() {
        let store = HealthHistoryStore(fileURL: fileURL)
        XCTAssertNil(store.lastResult(for: UUID()))
        XCTAssertEqual(store.results(for: UUID()), [])
    }

    @MainActor func testRingBufferTrimsToMaxResultsPerEndpoint() {
        let store = HealthHistoryStore(fileURL: fileURL)
        let endpointId = UUID()

        for i in 0..<(HealthHistoryStore.maxResultsPerEndpoint + 10) {
            store.record(makeResult(endpointId: endpointId, isHealthy: i % 2 == 0))
        }

        XCTAssertEqual(store.results(for: endpointId).count, HealthHistoryStore.maxResultsPerEndpoint)
    }

    @MainActor func testHistoryPersistsAcrossStoreInstances() {
        let endpointId = UUID()
        let first = HealthHistoryStore(fileURL: fileURL)
        first.record(makeResult(endpointId: endpointId, isHealthy: true))

        let second = HealthHistoryStore(fileURL: fileURL)
        XCTAssertEqual(second.results(for: endpointId).count, 1)
        XCTAssertEqual(second.lastResult(for: endpointId)?.isHealthy, true)
    }

    @MainActor func testRemoveHistoryClearsEndpoint() {
        let store = HealthHistoryStore(fileURL: fileURL)
        let endpointId = UUID()
        store.record(makeResult(endpointId: endpointId, isHealthy: true))

        store.removeHistory(for: endpointId)

        XCTAssertEqual(store.results(for: endpointId), [])
        XCTAssertNil(store.lastResult(for: endpointId))
    }
}
