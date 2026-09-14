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

        store.removeEndpoint(id: endpoint.id, retainData: false)
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
        store.removeEndpoint(id: original.id, retainData: false) // simulate accidental deletion

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

    // MARK: - allGroups

    @MainActor func testAllGroupsIsEmptyWhenNoEndpointsHaveGroups() {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "A"))
        store.addEndpoint(makeEndpoint(name: "B"))
        XCTAssertEqual(store.allGroups, [])
    }

    @MainActor func testAllGroupsReturnsDistinctSortedNames() {
        let store = EndpointStore(defaults: defaults)
        var a = makeEndpoint(name: "A"); a.group = "Zebra"
        var b = makeEndpoint(name: "B"); b.group = "apple"
        var c = makeEndpoint(name: "C"); c.group = "Mango"
        var d = makeEndpoint(name: "D"); d.group = "apple"
        [a, b, c, d].forEach { store.addEndpoint($0) }
        XCTAssertEqual(store.allGroups, ["apple", "Mango", "Zebra"])
    }

    @MainActor func testAllGroupsExcludesBlankAndWhitespaceOnlyGroups() {
        let store = EndpointStore(defaults: defaults)
        var a = makeEndpoint(name: "A"); a.group = ""
        var b = makeEndpoint(name: "B"); b.group = "   "
        var c = makeEndpoint(name: "C"); c.group = nil
        [a, b, c].forEach { store.addEndpoint($0) }
        XCTAssertEqual(store.allGroups, [])
    }

    @MainActor func testAllGroupsTrimsWhitespace() {
        let store = EndpointStore(defaults: defaults)
        var a = makeEndpoint(name: "A"); a.group = "  Production  "
        store.addEndpoint(a)
        XCTAssertEqual(store.allGroups, ["Production"])
    }

    // MARK: - groupedByGroupName

    func testGroupedByGroupNameOnEmptyArrayReturnsEmptyArray() {
        let endpoints: [Endpoint] = []
        XCTAssertEqual(endpoints.groupedByGroupName().count, 0)
    }

    func testGroupedByGroupNameWithNoGroupsReturnsSingleUngroupedSection() {
        let endpoints = [makeEndpoint(name: "A"), makeEndpoint(name: "B")]
        let sections = endpoints.groupedByGroupName()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.title, EndpointGroupSection.ungroupedTitle)
        XCTAssertEqual(sections.first?.endpoints.count, 2)
    }

    func testGroupedByGroupNameSortsGroupsCaseInsensitivelyWithUngroupedLast() {
        var staging = makeEndpoint(name: "S"); staging.group = "staging"
        var production = makeEndpoint(name: "P"); production.group = "Production"
        let ungrouped = makeEndpoint(name: "U")
        let sections = [staging, production, ungrouped].groupedByGroupName()
        XCTAssertEqual(sections.map(\.title), ["Production", "staging", EndpointGroupSection.ungroupedTitle])
    }

    func testGroupedByGroupNameOmitsUngroupedSectionWhenAllEndpointsHaveGroups() {
        var a = makeEndpoint(name: "A"); a.group = "Production"
        let sections = [a].groupedByGroupName()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.title, "Production")
    }

    // MARK: - removeEndpoint retainData / retainedDeletedEndpoints

    @MainActor func testRemoveEndpointWithRetainDataAddsRetainedRecord() {
        let store = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint(name: "Kept")
        store.addEndpoint(endpoint)

        store.removeEndpoint(id: endpoint.id, retainData: true)

        XCTAssertTrue(store.endpoints.isEmpty)
        XCTAssertEqual(store.retainedDeletedEndpoints.count, 1)
        XCTAssertEqual(store.retainedDeletedEndpoints.first?.id, endpoint.id)
        XCTAssertEqual(store.retainedDeletedEndpoints.first?.name, "Kept")
        XCTAssertEqual(store.retainedDeletedEndpoints.first?.url, endpoint.url)
    }

    @MainActor func testRemoveEndpointWithoutRetainDataAddsNoRetainedRecord() {
        let store = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint()
        store.addEndpoint(endpoint)

        store.removeEndpoint(id: endpoint.id, retainData: false)

        XCTAssertEqual(store.retainedDeletedEndpoints, [])
    }

    @MainActor func testMatchingRetainedEndpointIsCaseInsensitive() {
        let store = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint()
        store.addEndpoint(endpoint)
        store.removeEndpoint(id: endpoint.id, retainData: true)

        let upperURL = URL(string: endpoint.url.absoluteString.uppercased())!
        XCTAssertEqual(store.matchingRetainedEndpoint(forURL: upperURL)?.id, endpoint.id)
    }

    @MainActor func testMatchingRetainedEndpointReturnsNilWhenNoneMatch() {
        let store = EndpointStore(defaults: defaults)
        XCTAssertNil(store.matchingRetainedEndpoint(forURL: URL(string: "https://nomatch.test")!))
    }

    @MainActor func testReclaimRetainedEndpointRemovesRecord() {
        let store = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint()
        store.addEndpoint(endpoint)
        store.removeEndpoint(id: endpoint.id, retainData: true)
        XCTAssertEqual(store.retainedDeletedEndpoints.count, 1)

        store.reclaimRetainedEndpoint(id: endpoint.id)
        XCTAssertEqual(store.retainedDeletedEndpoints, [])
    }

    @MainActor func testRetainedDeletedEndpointsPersistAcrossStoreInstances() {
        let first = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint(name: "Persisted")
        first.addEndpoint(endpoint)
        first.removeEndpoint(id: endpoint.id, retainData: true)

        let second = EndpointStore(defaults: defaults)
        XCTAssertEqual(second.retainedDeletedEndpoints.count, 1)
        XCTAssertEqual(second.retainedDeletedEndpoints.first?.id, endpoint.id)
        XCTAssertEqual(second.retainedDeletedEndpoints.first?.name, "Persisted")
    }
}
