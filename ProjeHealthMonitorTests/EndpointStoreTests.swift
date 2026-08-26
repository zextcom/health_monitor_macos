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
        XCTAssertEqual(store.globalCheckInterval, EndpointStore.defaultGlobalCheckInterval)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertTrue(store.notifyOnRecovery)
        XCTAssertFalse(store.launchAtLoginEnabled)
        XCTAssertEqual(store.requestTimeout, EndpointStore.defaultRequestTimeout)
        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    @MainActor func testOnboardingFlagPersistsAcrossStoreInstances() {
        let first = EndpointStore(defaults: defaults)
        first.hasCompletedOnboarding = true

        let second = EndpointStore(defaults: defaults)
        XCTAssertTrue(second.hasCompletedOnboarding)
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

    @MainActor func testPersistedTimingSettingsAreNormalizedOnLoad() {
        defaults.set(0.5, forKey: "globalCheckInterval")
        defaults.set(120.0, forKey: "requestTimeout")

        let store = EndpointStore(defaults: defaults)

        XCTAssertEqual(store.globalCheckInterval, EndpointStore.minimumCheckInterval)
        XCTAssertEqual(store.requestTimeout, EndpointStore.maximumRequestTimeout)
    }

    @MainActor func testEndpointCustomIntervalsAreNormalizedOnLoad() throws {
        var endpoint = makeEndpoint()
        endpoint.checkIntervalOverride = 1
        defaults.set(try JSONEncoder().encode([endpoint]), forKey: "endpoints")

        let store = EndpointStore(defaults: defaults)

        XCTAssertEqual(store.endpoints.first?.checkIntervalOverride, EndpointStore.minimumCheckInterval)
    }

    @MainActor func testTimingSettingsAreNormalizedBeforePersisting() {
        let store = EndpointStore(defaults: defaults)

        store.globalCheckInterval = -5
        store.requestTimeout = 0

        XCTAssertEqual(store.globalCheckInterval, EndpointStore.minimumCheckInterval)
        XCTAssertEqual(store.requestTimeout, EndpointStore.minimumRequestTimeout)
        XCTAssertEqual(defaults.double(forKey: "globalCheckInterval"), EndpointStore.minimumCheckInterval)
        XCTAssertEqual(defaults.double(forKey: "requestTimeout"), EndpointStore.minimumRequestTimeout)
    }

    @MainActor func testEndpointCustomIntervalsAreNormalizedBeforePersisting() {
        let store = EndpointStore(defaults: defaults)
        var endpoint = makeEndpoint()
        endpoint.checkIntervalOverride = 1

        store.addEndpoint(endpoint)

        XCTAssertEqual(store.endpoints.first?.checkIntervalOverride, EndpointStore.minimumCheckInterval)
    }

    @MainActor func testURLValidationAllowsOnlyHTTPOrHTTPSForHTTPChecks() {
        XCTAssertNotNil(EndpointStore.validatedURL("https://example.test/health", checkType: .http))
        XCTAssertNotNil(EndpointStore.validatedURL("http://example.test/health", checkType: .http))
        XCTAssertNil(EndpointStore.validatedURL("file:///tmp/health.json", checkType: .http))
        XCTAssertNil(EndpointStore.validatedURL("https:///missing-host", checkType: .http))
        XCTAssertNil(EndpointStore.validatedURL("https://example.test:99999/health", checkType: .http))
        XCTAssertNil(EndpointStore.validatedURL("https://example.test:/health", checkType: .http))
        XCTAssertNil(EndpointStore.validatedURL("https://example.test:abc/health", checkType: .http))
    }

    @MainActor func testURLValidationRequiresTCPHostAndPortForTCPChecks() {
        XCTAssertNotNil(EndpointStore.validatedURL("tcp://db.example.test:5432", checkType: .tcp))
        XCTAssertNil(EndpointStore.validatedURL("https://db.example.test:5432", checkType: .tcp))
        XCTAssertNil(EndpointStore.validatedURL("tcp://db.example.test", checkType: .tcp))
        XCTAssertNil(EndpointStore.validatedURL("tcp://db.example.test:99999", checkType: .tcp))
    }

    @MainActor func testStatusCodeValidationIsLimitedToHTTPRange() {
        XCTAssertEqual(EndpointStore.validatedHTTPStatusCode("200"), 200)
        XCTAssertEqual(EndpointStore.validatedHTTPStatusCode(" 503 "), 503)
        XCTAssertNil(EndpointStore.validatedHTTPStatusCode("99"))
        XCTAssertNil(EndpointStore.validatedHTTPStatusCode("600"))
        XCTAssertNil(EndpointStore.validatedHTTPStatusCode("abc"))
    }

    @MainActor func testExportDataRoundTripsThroughDecode() throws {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "A"))
        store.addEndpoint(makeEndpoint(name: "B"))

        let data = try XCTUnwrap(store.exportData())
        let decoded = try JSONDecoder().decode([Endpoint].self, from: data)
        XCTAssertEqual(decoded, store.endpoints)
    }

    @MainActor func testImportAddsNewEndpoints() throws {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "Existing"))

        let incoming = [makeEndpoint(name: "Imported")]
        let data = try JSONEncoder().encode(incoming)

        try store.importEndpoints(from: data)

        XCTAssertEqual(store.endpoints.count, 2)
        XCTAssertTrue(store.endpoints.contains { $0.name == "Imported" })
        XCTAssertTrue(store.endpoints.contains { $0.name == "Existing" })
    }

    @MainActor func testImportRestoresExistingEndpointByID() throws {
        let store = EndpointStore(defaults: defaults)
        let original = makeEndpoint(name: "Original")
        store.addEndpoint(original)
        store.removeEndpoint(id: original.id) // simulate accidental deletion

        let data = try JSONEncoder().encode([original])
        try store.importEndpoints(from: data)

        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertEqual(store.endpoints.first?.id, original.id)
        XCTAssertEqual(store.endpoints.first?.name, "Original")
    }

    @MainActor func testImportUpdatesEndpointWithMatchingID() throws {
        let store = EndpointStore(defaults: defaults)
        var endpoint = makeEndpoint(name: "Old Name")
        store.addEndpoint(endpoint)

        endpoint.name = "New Name"
        let data = try JSONEncoder().encode([endpoint])
        try store.importEndpoints(from: data)

        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertEqual(store.endpoints.first?.name, "New Name")
    }

    @MainActor func testImportThrowsOnInvalidData() {
        let store = EndpointStore(defaults: defaults)
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try store.importEndpoints(from: garbage))
    }

    @MainActor func testCorruptStoredDataIsNotOverwrittenOnLaunch() throws {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "endpoints")

        let store = EndpointStore(defaults: defaults)
        XCTAssertEqual(store.endpoints, [], "in-memory list falls back to empty when decode fails")

        // The raw bytes on disk must be untouched by the failed decode, so they remain
        // available for recovery/inspection instead of being silently replaced with `[]`.
        let onDisk = try XCTUnwrap(defaults.data(forKey: "endpoints"))
        XCTAssertEqual(onDisk, corrupt)
    }
}
