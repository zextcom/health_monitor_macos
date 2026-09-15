import XCTest
@testable import ProjeHealthMonitor

/// Mirrors the shape `EndpointStore`'s own sync payload encodes (its wrapper type is private)
/// so tests can construct/decode real iCloud key-value store contents rather than reaching into
/// internals — same pattern as `StatusPageDecodedPayload` in HealthCheckServiceTests.
private struct EndpointSyncPayload: Codable {
    let endpoints: [Endpoint]
    let modifiedAt: Date
}

private final class FakeUbiquitousStore: UbiquitousKeyValueStoring {
    private var storage: [String: Data] = [:]
    private(set) var setCallCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func set(_ value: Data?, forKey key: String) {
        setCallCount += 1
        storage[key] = value
    }

    func latestPayload(forKey key: String) -> EndpointSyncPayload? {
        guard let data = storage[key] else { return nil }
        return try? JSONDecoder().decode(EndpointSyncPayload.self, from: data)
    }

    func seed(endpoints: [Endpoint], modifiedAt: Date, forKey key: String) {
        let payload = EndpointSyncPayload(endpoints: endpoints, modifiedAt: modifiedAt)
        storage[key] = try? JSONEncoder().encode(payload)
    }
}

final class EndpointStoreICloudSyncTests: XCTestCase {
    private static let syncKey = "com.zext.healthmonitor.endpointsSync"

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var ubiquitousStore: FakeUbiquitousStore!

    override func setUp() {
        super.setUp()
        suiteName = "EndpointStoreICloudSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        ubiquitousStore = FakeUbiquitousStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        ubiquitousStore = nil
        super.tearDown()
    }

    private func makeEndpoint(name: String = "Test") -> Endpoint {
        Endpoint(name: name, url: URL(string: "https://example.test/health")!)
    }

    @MainActor func testICloudSyncDisabledByDefault() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        XCTAssertFalse(store.iCloudSyncEnabled)
    }

    @MainActor func testEnablingSyncWithNoRemoteDataPushesLocalEndpoints() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.addEndpoint(makeEndpoint(name: "Local"))

        store.iCloudSyncEnabled = true

        let payload = ubiquitousStore.latestPayload(forKey: Self.syncKey)
        XCTAssertEqual(payload?.endpoints.map(\.name), ["Local"])
    }

    @MainActor func testChangingEndpointsWhileSyncEnabledPushesUpdate() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.iCloudSyncEnabled = true
        let countAfterEnabling = ubiquitousStore.setCallCount

        store.addEndpoint(makeEndpoint(name: "New"))

        XCTAssertGreaterThan(ubiquitousStore.setCallCount, countAfterEnabling)
        XCTAssertEqual(ubiquitousStore.latestPayload(forKey: Self.syncKey)?.endpoints.map(\.name), ["New"])
    }

    @MainActor func testChangingEndpointsWhileSyncDisabledDoesNotPush() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.addEndpoint(makeEndpoint())
        XCTAssertEqual(ubiquitousStore.setCallCount, 0)
    }

    @MainActor func testEnablingSyncPullsDownNewerRemoteEndpoints() {
        ubiquitousStore.seed(endpoints: [makeEndpoint(name: "FromOtherMac")], modifiedAt: Date(), forKey: Self.syncKey)

        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.addEndpoint(makeEndpoint(name: "LocalOnly"))

        store.iCloudSyncEnabled = true

        XCTAssertEqual(store.endpoints.map(\.name), ["FromOtherMac"])
    }

    @MainActor func testExternalChangeNotificationAppliesNewerRemotePayload() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.iCloudSyncEnabled = true

        ubiquitousStore.seed(endpoints: [makeEndpoint(name: "PushedFromOtherMac")],
                              modifiedAt: Date().addingTimeInterval(60),
                              forKey: Self.syncKey)
        store.applyRemoteSyncPayloadIfNewer()

        XCTAssertEqual(store.endpoints.map(\.name), ["PushedFromOtherMac"])
    }

    @MainActor func testApplyingRemotePayloadDoesNotImmediatelyRePush() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.iCloudSyncEnabled = true
        let countAfterEnabling = ubiquitousStore.setCallCount

        ubiquitousStore.seed(endpoints: [makeEndpoint(name: "PushedFromOtherMac")],
                              modifiedAt: Date().addingTimeInterval(60),
                              forKey: Self.syncKey)
        store.applyRemoteSyncPayloadIfNewer()

        // Applying the incoming payload updates local state, but must not trigger a fresh push —
        // otherwise two synced Macs would keep re-triggering each other's change notification.
        XCTAssertEqual(ubiquitousStore.setCallCount, countAfterEnabling)
    }

    @MainActor func testOlderRemotePayloadIsIgnored() {
        let store = EndpointStore(defaults: defaults, ubiquitousStore: ubiquitousStore)
        store.iCloudSyncEnabled = true
        store.addEndpoint(makeEndpoint(name: "Newer"))

        // A stale payload from before the local change above must not overwrite it.
        ubiquitousStore.seed(endpoints: [makeEndpoint(name: "Older")],
                              modifiedAt: Date().addingTimeInterval(-3600),
                              forKey: Self.syncKey)
        store.applyRemoteSyncPayloadIfNewer()

        XCTAssertEqual(store.endpoints.map(\.name), ["Newer"])
    }
}
