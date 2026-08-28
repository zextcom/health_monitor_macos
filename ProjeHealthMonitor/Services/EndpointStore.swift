import Foundation

enum EndpointGrouping {
    static let ungroupedTitle = "Ungrouped"

    static func normalizedGroupName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedGroupNames(from rawValues: [String?]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for value in rawValues {
            guard let value, let normalizedValue = normalizedGroupName(value), !seen.contains(normalizedValue) else { continue }
            seen.insert(normalizedValue)
            normalized.append(normalizedValue)
        }

        return normalized.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func suggestedGroupNames(from groupNames: [String], excluding currentInput: String) -> [String] {
        let excludedGroupName = normalizedGroupName(currentInput)
        return normalizedGroupNames(from: groupNames)
            .filter { $0 != excludedGroupName }
    }

    static func matchesSearch(_ endpoint: Endpoint, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        return endpoint.name.localizedCaseInsensitiveContains(trimmed)
            || endpoint.url.absoluteString.localizedCaseInsensitiveContains(trimmed)
            || (endpoint.groupName?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }
}

struct EndpointGroupSection: Identifiable, Equatable {
    static let ungroupedTitle = EndpointGrouping.ungroupedTitle

    let groupName: String?
    let endpoints: [Endpoint]

    var id: String { groupName ?? "__ungrouped__" }
    var title: String { groupName ?? Self.ungroupedTitle }
    var isUngrouped: Bool { groupName == nil }
}

@MainActor
final class EndpointStore: ObservableObject {
    private enum Keys {
        static let endpoints = "endpoints"
        static let globalCheckInterval = "globalCheckInterval"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnRecovery = "notifyOnRecovery"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let requestTimeout = "requestTimeout"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    @Published var endpoints: [Endpoint] {
        didSet { persistEndpoints() }
    }
    @Published var globalCheckInterval: TimeInterval {
        didSet { defaults.set(globalCheckInterval, forKey: Keys.globalCheckInterval) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var notifyOnRecovery: Bool {
        didSet { defaults.set(notifyOnRecovery, forKey: Keys.notifyOnRecovery) }
    }
    @Published var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled) }
    }
    @Published var requestTimeout: TimeInterval {
        didSet { defaults.set(requestTimeout, forKey: Keys.requestTimeout) }
    }
    /// Set once the app has auto-opened Settings on first launch, so returning users who clear
    /// their endpoint list don't get it reopened on every launch.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults
    /// Guards `persistEndpoints()` from running as a side effect of the `didSet` firing during
    /// `init`'s own assignment — without this, a decode failure on existing data would
    /// immediately overwrite it on disk with an empty array before we ever hand control back.
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.endpoints),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            self.endpoints = decoded
        } else {
            self.endpoints = []
        }

        let storedInterval = defaults.double(forKey: Keys.globalCheckInterval)
        self.globalCheckInterval = storedInterval > 0 ? storedInterval : 60

        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.notifyOnRecovery = defaults.object(forKey: Keys.notifyOnRecovery) as? Bool ?? true
        self.launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? false

        let storedTimeout = defaults.double(forKey: Keys.requestTimeout)
        self.requestTimeout = storedTimeout > 0 ? storedTimeout : 10

        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false

        isLoading = false
    }

    func addEndpoint(_ endpoint: Endpoint) {
        endpoints.append(endpoint)
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
    }

    func removeEndpoint(id: UUID) {
        endpoints.removeAll { $0.id == id }
    }

    /// User-entered groups are lightweight metadata derived entirely from endpoints; there is no
    /// separate group store, so suggestions come from currently used group names.
    var usedGroupNames: [String] {
        EndpointGrouping.normalizedGroupNames(from: endpoints.map(\.groupName))
    }

    func filteredEndpoints(matching query: String, within endpoints: [Endpoint]? = nil) -> [Endpoint] {
        let source = endpoints ?? self.endpoints
        return source.filter { EndpointGrouping.matchesSearch($0, query: query) }
    }

    func groupedSections(for endpoints: [Endpoint]? = nil) -> [EndpointGroupSection] {
        let source = endpoints ?? self.endpoints
        var namedGroups: [String: [Endpoint]] = [:]
        var ungrouped: [Endpoint] = []

        for endpoint in source {
            guard let groupName = EndpointGrouping.normalizedGroupName(endpoint.groupName ?? "") else {
                ungrouped.append(endpoint)
                continue
            }
            namedGroups[groupName, default: []].append(endpoint)
        }

        var sections = namedGroups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { EndpointGroupSection(groupName: $0, endpoints: namedGroups[$0] ?? []) }

        if !ungrouped.isEmpty {
            sections.append(EndpointGroupSection(groupName: nil, endpoints: ungrouped))
        }

        return sections
    }

    /// Endpoint configuration only — no auth secrets (those live in `SecretStore`/Keychain and
    /// are deliberately excluded from exports so a backup file is safe to share/store).
    func exportData() -> Data? {
        try? JSONEncoder().encode(endpoints)
    }

    /// Merges by endpoint `id`: an imported endpoint whose id matches an existing one restores/
    /// overwrites it in place, anything else is added. Nothing already in the store is removed —
    /// importing is additive/restorative, never destructive, so a mis-chosen file can't itself
    /// cause data loss.
    func importEndpoints(from data: Data) throws {
        let imported = try JSONDecoder().decode([Endpoint].self, from: data)
        for endpoint in imported {
            if endpoints.contains(where: { $0.id == endpoint.id }) {
                updateEndpoint(endpoint)
            } else {
                addEndpoint(endpoint)
            }
        }
    }

    private func persistEndpoints() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        defaults.set(data, forKey: Keys.endpoints)
    }
}
