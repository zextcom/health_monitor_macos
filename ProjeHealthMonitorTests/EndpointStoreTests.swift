import XCTest
@testable import ProjeHealthMonitor

final class EndpointStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "EndpointStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeEndpoint(name: String = "Test") -> Endpoint {
        Endpoint(name: name, url: URL(string: "https://example.test/health")!)
    }

    @MainActor func testDefaultsAreSeededOnFirstLaunch() {
        let store = EndpointStore(defaults: defaults)
        XCTAssertEqual(store.endpoints, [])
        XCTAssertEqual(store.globalCheckInterval, 60)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertTrue(store.notifyOnRecovery)
        XCTAssertFalse(store.launchAtLoginEnabled)
        XCTAssertEqual(store.requestTimeout, 10)
    }

    @MainActor func testAddUpdateRemoveEndpoint() {
        let store = EndpointStore(defaults: defaults)
        var endpoint = makeEndpoint()

        store.addEndpoint(endpoint)
        XCTAssertEqual(store.endpoints.count, 1)

        endpoint.name = "Renamed"
        store.updateEndpoint(endpoint)
        XCTAssertEqual(store.endpoints.first?.name, "Renamed")

        store.removeEndpoint(id: endpoint.id)
        XCTAssertTrue(store.endpoints.isEmpty)
    }

    @MainActor func testUpdateEndpointWithUnknownIdIsANoOp() {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint())
        let stray = makeEndpoint(name: "Stray")
        store.updateEndpoint(stray)
        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertNil(store.endpoints.first(where: { $0.id == stray.id }))
    }

    @MainActor func testEndpointsPersistAcrossStoreInstances() {
        let first = EndpointStore(defaults: defaults)
        first.addEndpoint(makeEndpoint(name: "Persisted"))

        let second = EndpointStore(defaults: defaults)
        XCTAssertEqual(second.endpoints.count, 1)
        XCTAssertEqual(second.endpoints.first?.name, "Persisted")
    }

    @MainActor func testSettingsPersistAcrossStoreInstances() {
        let first = EndpointStore(defaults: defaults)
        first.globalCheckInterval = 300
        first.notificationsEnabled = false
        first.notifyOnRecovery = false
        first.requestTimeout = 20

        let second = EndpointStore(defaults: defaults)
        XCTAssertEqual(second.globalCheckInterval, 300)
        XCTAssertFalse(second.notificationsEnabled)
        XCTAssertFalse(second.notifyOnRecovery)
        XCTAssertEqual(second.requestTimeout, 20)
    }
}
