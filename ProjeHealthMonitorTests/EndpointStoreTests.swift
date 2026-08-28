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

    private func makeEndpoint(name: String = "Test", groupName: String? = nil) -> Endpoint {
        Endpoint(name: name, url: URL(string: "https://example.test/health")!, groupName: groupName)
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

    @MainActor func testExportDataRoundTripsThroughDecode() throws {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "A", groupName: "Backend"))
        store.addEndpoint(makeEndpoint(name: "B"))

        let data = try XCTUnwrap(store.exportData())
        let decoded = try JSONDecoder().decode([Endpoint].self, from: data)
        XCTAssertEqual(decoded, store.endpoints)
    }

    @MainActor func testImportAddsNewEndpoints() throws {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "Existing"))

        let incoming = [makeEndpoint(name: "Imported", groupName: "Backend")]
        let data = try JSONEncoder().encode(incoming)

        try store.importEndpoints(from: data)

        XCTAssertEqual(store.endpoints.count, 2)
        XCTAssertTrue(store.endpoints.contains { $0.name == "Imported" })
        XCTAssertTrue(store.endpoints.contains { $0.name == "Existing" })
        XCTAssertEqual(store.endpoints.first(where: { $0.name == "Imported" })?.groupName, "Backend")
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
        endpoint.groupName = "Backend"
        let data = try JSONEncoder().encode([endpoint])
        try store.importEndpoints(from: data)

        XCTAssertEqual(store.endpoints.count, 1)
        XCTAssertEqual(store.endpoints.first?.name, "New Name")
        XCTAssertEqual(store.endpoints.first?.groupName, "Backend")
    }

    func testEndpointRoundTripsGroupNameThroughCodable() throws {
        let endpoint = makeEndpoint(name: "API", groupName: "Backend")

        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(Endpoint.self, from: data)

        XCTAssertEqual(decoded, endpoint)
        XCTAssertEqual(decoded.groupName, "Backend")
    }

    func testEndpointDecodesLegacyPayloadWithoutGroupName() throws {
        let json = """
        {
          "id": "B9C5B886-6B31-4B30-8D5C-E3DF02EF5A57",
          "name": "Legacy",
          "url": "https://example.test/health",
          "expectedStatusCode": 200,
          "jsonAssertions": [],
          "authType": "none"
        }
        """

        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(json.utf8))

        XCTAssertEqual(endpoint.name, "Legacy")
        XCTAssertNil(endpoint.groupName)
        XCTAssertEqual(endpoint.checkType, .http)
    }

    func testNormalizedGroupNameReturnsNilForBlankInput() {
        XCTAssertNil(EndpointGrouping.normalizedGroupName(""))
        XCTAssertNil(EndpointGrouping.normalizedGroupName("   "))
        XCTAssertNil(EndpointGrouping.normalizedGroupName("\n\t"))
    }

    func testNormalizedGroupNameTrimsAndPreservesEnteredValue() {
        XCTAssertEqual(EndpointGrouping.normalizedGroupName("  Backend API  "), "Backend API")
    }

    func testSuggestedGroupNamesExcludesBlankAndCurrentGroup() {
        let suggestions = EndpointGrouping.suggestedGroupNames(
            from: ["Backend", " ", "Ops", "Backend", "  Alerts  "],
            excluding: "  Ops "
        )

        XCTAssertEqual(suggestions, ["Alerts", "Backend"])
    }

    @MainActor func testUsedGroupNamesAndGroupedSections() {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "API A", groupName: "Backend"))
        store.addEndpoint(makeEndpoint(name: "Ungrouped"))
        store.addEndpoint(makeEndpoint(name: "API B", groupName: "Backend"))
        store.addEndpoint(makeEndpoint(name: "Pager", groupName: "Alerts"))

        XCTAssertEqual(store.usedGroupNames, ["Alerts", "Backend"])

        let sections = store.groupedSections()
        XCTAssertEqual(sections.map(\.title), ["Alerts", "Backend", "Ungrouped"])
        XCTAssertEqual(sections[0].endpoints.map(\.name), ["Pager"])
        XCTAssertEqual(sections[1].endpoints.map(\.name), ["API A", "API B"])
        XCTAssertEqual(sections[2].endpoints.map(\.name), ["Ungrouped"])
        XCTAssertTrue(sections[2].isUngrouped)
    }

    @MainActor func testGroupedSectionsTreatWhitespaceOnlyGroupsAsUngrouped() {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "Whitespace Group", groupName: "   "))
        store.addEndpoint(makeEndpoint(name: "API", groupName: "Backend"))

        let sections = store.groupedSections()

        XCTAssertEqual(sections.map(\.title), ["Backend", "Ungrouped"])
        XCTAssertEqual(sections.last?.endpoints.map(\.name), ["Whitespace Group"])
    }

    @MainActor func testFilteredEndpointsMatchesGroupName() {
        let store = EndpointStore(defaults: defaults)
        store.addEndpoint(makeEndpoint(name: "Primary API", groupName: "Backend"))
        store.addEndpoint(makeEndpoint(name: "Status Page", groupName: "Ops"))

        XCTAssertEqual(store.filteredEndpoints(matching: "backend").map(\.name), ["Primary API"])
        XCTAssertEqual(store.filteredEndpoints(matching: "status").map(\.name), ["Status Page"])
        XCTAssertEqual(store.filteredEndpoints(matching: "").map(\.name), ["Primary API", "Status Page"])
    }

    @MainActor func testUngroupedEndpointRemainsVisibleInGroupedViews() {
        let store = EndpointStore(defaults: defaults)
        let endpoint = makeEndpoint(name: "Legacy Flat Endpoint")
        store.addEndpoint(endpoint)

        XCTAssertNil(endpoint.groupName)
        XCTAssertEqual(store.groupedSections().last?.title, "Ungrouped")
        XCTAssertEqual(store.groupedSections().last?.endpoints.map(\.name), ["Legacy Flat Endpoint"])
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
