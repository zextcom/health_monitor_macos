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

    private let defaults: UserDefaults

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

    private func persistEndpoints() {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        defaults.set(data, forKey: Keys.endpoints)
    }
}
