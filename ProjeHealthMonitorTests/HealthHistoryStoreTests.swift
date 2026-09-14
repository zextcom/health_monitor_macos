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

    /// `saveDebounceInterval: 0` makes `record()`/`removeHistory()` save synchronously, matching
    /// the pre-debounce behavior these tests (which read back via a second store instance) rely on.
    @MainActor
    private func makeStore(safetyCapPerEndpoint: Int = HealthHistoryStore.defaultSafetyCapPerEndpoint) -> HealthHistoryStore {
        HealthHistoryStore(fileURL: fileURL, saveDebounceInterval: 0, safetyCapPerEndpoint: safetyCapPerEndpoint)
    }

    @MainActor func testRecordAppendsAndLastResultReturnsMostRecent() {
        let store = makeStore()
        let endpointId = UUID()

        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 10), retentionDays: 7)
        store.record(makeResult(endpointId: endpointId, isHealthy: false, secondsAgo: 0), retentionDays: 7)

        XCTAssertEqual(store.results(for: endpointId).count, 2)
        XCTAssertEqual(store.lastResult(for: endpointId)?.isHealthy, false)
    }

    @MainActor func testLastResultIsNilForUnknownEndpoint() {
        let store = makeStore()
        XCTAssertNil(store.lastResult(for: UUID()))
        XCTAssertEqual(store.results(for: UUID()), [])
    }

    @MainActor func testRecordPrunesResultsOlderThanRetentionWindow() {
        let store = makeStore()
        let endpointId = UUID()

        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 10 * 86400), retentionDays: 7)
        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 0), retentionDays: 7)

        XCTAssertEqual(store.results(for: endpointId).count, 1, "the 10-day-old result should have been pruned by a 7-day retention window")
    }

    @MainActor func testRecordKeepsResultsWithinRetentionWindow() {
        let store = makeStore()
        let endpointId = UUID()

        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 3 * 86400), retentionDays: 7)
        store.record(makeResult(endpointId: endpointId, isHealthy: true, secondsAgo: 0), retentionDays: 7)

        XCTAssertEqual(store.results(for: endpointId).count, 2)
    }

    @MainActor func testSafetyCapTrimsPathologicallyLargeHistoryRegardlessOfDate() {
        let store = makeStore(safetyCapPerEndpoint: 5)
        let endpointId = UUID()

        // All within the retention window (secondsAgo: 0), so only the safety cap can bound this.
        for i in 0..<10 {
            store.record(makeResult(endpointId: endpointId, isHealthy: i % 2 == 0), retentionDays: 30)
        }

        XCTAssertEqual(store.results(for: endpointId).count, 5)
    }

    @MainActor func testHistoryPersistsAcrossStoreInstances() {
        let endpointId = UUID()
        let first = makeStore()
        first.record(makeResult(endpointId: endpointId, isHealthy: true), retentionDays: 7)

        let second = makeStore()
        XCTAssertEqual(second.results(for: endpointId).count, 1)
        XCTAssertEqual(second.lastResult(for: endpointId)?.isHealthy, true)
    }

    @MainActor func testRemoveHistoryClearsEndpoint() {
        let store = makeStore()
        let endpointId = UUID()
        store.record(makeResult(endpointId: endpointId, isHealthy: true), retentionDays: 7)

        store.removeHistory(for: endpointId)

        XCTAssertEqual(store.results(for: endpointId), [])
        XCTAssertNil(store.lastResult(for: endpointId))
    }
}
