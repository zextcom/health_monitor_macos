import Foundation

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
