import XCTest
@testable import ProjeHealthMonitor

final class DailyStatsStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyStatsStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        super.tearDown()
    }

    @MainActor func testRecordCreatesTodaysBucket() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()

        store.record(endpointId: endpointId, timestamp: Date(), isHealthy: true, intervalSeconds: 60)

        let today = store.dailyStats(for: endpointId, days: 1).first
        XCTAssertEqual(today?.stat?.totalChecks, 1)
        XCTAssertEqual(today?.stat?.downChecks, 0)
        XCTAssertEqual(today?.stat?.downtimeSeconds, 0)
    }

    @MainActor func testMultipleChecksSameDayAreAggregated() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()
        let now = Date()

        store.record(endpointId: endpointId, timestamp: now, isHealthy: true, intervalSeconds: 60)
        store.record(endpointId: endpointId, timestamp: now.addingTimeInterval(60), isHealthy: false, intervalSeconds: 60)
        store.record(endpointId: endpointId, timestamp: now.addingTimeInterval(120), isHealthy: false, intervalSeconds: 60)

        let today = store.dailyStats(for: endpointId, days: 1, referenceDate: now).first
        XCTAssertEqual(today?.stat?.totalChecks, 3)
        XCTAssertEqual(today?.stat?.downChecks, 2)
        XCTAssertEqual(today?.stat?.downtimeSeconds, 120)
    }

    @MainActor func testChecksOnDifferentDaysAreSeparateBuckets() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        store.record(endpointId: endpointId, timestamp: yesterday, isHealthy: false, intervalSeconds: 60)
        store.record(endpointId: endpointId, timestamp: today, isHealthy: true, intervalSeconds: 60)

        let last2Days = store.dailyStats(for: endpointId, days: 2, referenceDate: today)
        XCTAssertEqual(last2Days.count, 2)
        XCTAssertEqual(last2Days[0].stat?.downChecks, 1) // yesterday
        XCTAssertEqual(last2Days[1].stat?.totalChecks, 1) // today
        XCTAssertEqual(last2Days[1].stat?.downChecks, 0)
    }

    @MainActor func testDailyStatsReturnsNilForDaysWithNoData() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()

        let last7Days = store.dailyStats(for: endpointId, days: 7)
        XCTAssertEqual(last7Days.count, 7)
        XCTAssertTrue(last7Days.allSatisfy { $0.stat == nil })
    }

    @MainActor func testDailyStatsIsOrderedOldestFirst() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()
        let today = Date()

        let days = store.dailyStats(for: endpointId, days: 5, referenceDate: today)
        for i in 0..<(days.count - 1) {
            XCTAssertLessThan(days[i].date, days[i + 1].date)
        }
        XCTAssertEqual(Calendar.current.isDateInToday(days.last!.date), true)
    }

    @MainActor func testStatsPersistAcrossStoreInstances() {
        let endpointId = UUID()
        let first = DailyStatsStore(fileURL: fileURL)
        first.record(endpointId: endpointId, timestamp: Date(), isHealthy: false, intervalSeconds: 30)

        let second = DailyStatsStore(fileURL: fileURL)
        let today = second.dailyStats(for: endpointId, days: 1).first
        XCTAssertEqual(today?.stat?.downChecks, 1)
        XCTAssertEqual(today?.stat?.downtimeSeconds, 30)
    }

    @MainActor func testRemoveStatsClearsEndpoint() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()
        store.record(endpointId: endpointId, timestamp: Date(), isHealthy: true, intervalSeconds: 60)

        store.removeStats(for: endpointId)

        XCTAssertNil(store.dailyStats(for: endpointId, days: 1).first?.stat)
    }

    @MainActor func testOldDaysArePrunedBeyondRetentionWindow() {
        let store = DailyStatsStore(fileURL: fileURL)
        let endpointId = UUID()
        let today = Date()
        let longAgo = Calendar.current.date(byAdding: .day, value: -(DailyStatsStore.retentionDays + 20), to: today)!

        store.record(endpointId: endpointId, timestamp: longAgo, isHealthy: true, intervalSeconds: 60)
        store.record(endpointId: endpointId, timestamp: today, isHealthy: true, intervalSeconds: 60)

        // Old bucket should have been pruned by the second record() call (pruning is relative to
        // the most recent recorded timestamp).
        XCTAssertEqual(store.stats[endpointId]?.count, 1)
    }
}
