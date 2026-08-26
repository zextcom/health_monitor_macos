import Foundation
import OSLog

@MainActor
final class EndpointStore: ObservableObject {
    static let defaultGlobalCheckInterval: TimeInterval = 60
    static let minimumCheckInterval: TimeInterval = 10
    static let defaultRequestTimeout: TimeInterval = 10
    static let minimumRequestTimeout: TimeInterval = 1
    static let maximumRequestTimeout: TimeInterval = 60
    static let validStatusCodeRange = 100...599

    private static let logger = Logger(subsystem: "com.zext.healthmonitor", category: "EndpointStore")

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
        didSet {
            let normalized = Self.normalizedCheckInterval(globalCheckInterval)
            guard normalized == globalCheckInterval else {
                globalCheckInterval = normalized
                return
            }
            defaults.set(globalCheckInterval, forKey: Keys.globalCheckInterval)
        }
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
        didSet {
            let normalized = Self.normalizedRequestTimeout(requestTimeout)
            guard normalized == requestTimeout else {
                requestTimeout = normalized
                return
            }
            defaults.set(requestTimeout, forKey: Keys.requestTimeout)
        }
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

        if let data = defaults.data(forKey: Keys.endpoints) {
            do {
                self.endpoints = try JSONDecoder().decode([Endpoint].self, from: data).map(Self.normalizedEndpoint)
            } catch {
                Self.logger.error("Failed to decode stored endpoints: \(error.localizedDescription, privacy: .public)")
                self.endpoints = []
            }
        } else {
            self.endpoints = []
        }

        if let storedInterval = defaults.object(forKey: Keys.globalCheckInterval) as? TimeInterval {
            self.globalCheckInterval = Self.normalizedCheckInterval(storedInterval)
        } else {
            self.globalCheckInterval = Self.defaultGlobalCheckInterval
        }

        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.notifyOnRecovery = defaults.object(forKey: Keys.notifyOnRecovery) as? Bool ?? true
        self.launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? false

        if let storedTimeout = defaults.object(forKey: Keys.requestTimeout) as? TimeInterval {
            self.requestTimeout = Self.normalizedRequestTimeout(storedTimeout)
        } else {
            self.requestTimeout = Self.defaultRequestTimeout
        }

        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false

        isLoading = false
    }

    func addEndpoint(_ endpoint: Endpoint) {
        endpoints.append(Self.normalizedEndpoint(endpoint))
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = Self.normalizedEndpoint(endpoint)
    }

    func removeEndpoint(id: UUID) {
        endpoints.removeAll { $0.id == id }
    }

    static func normalizedCheckInterval(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultGlobalCheckInterval }
        return max(seconds, minimumCheckInterval)
    }

    static func normalizedRequestTimeout(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return defaultRequestTimeout }
        return min(max(seconds, minimumRequestTimeout), maximumRequestTimeout)
    }

    static func isValidCheckInterval(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= minimumCheckInterval
    }

    static func normalizedEndpoint(_ endpoint: Endpoint) -> Endpoint {
        var normalized = endpoint
        if let interval = normalized.checkIntervalOverride {
            normalized.checkIntervalOverride = normalizedCheckInterval(interval)
        }
        return normalized
    }

    static func validatedHTTPStatusCode(_ value: String) -> Int? {
        guard let statusCode = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              validStatusCodeRange.contains(statusCode)
        else { return nil }
        return statusCode
    }

    static func validatedURL(_ value: String, checkType: CheckType) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }

        switch checkType {
        case .http:
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil
            else { return nil }
            if let port = url.port, UInt16(exactly: port) == nil { return nil }
            return url
        case .tcp:
            guard url.scheme?.lowercased() == "tcp",
                  url.host != nil,
                  let port = url.port,
                  UInt16(exactly: port) != nil
            else { return nil }
            return url
        }
    }

    /// Endpoint configuration only — no auth secrets (those live in `SecretStore`/Keychain and
    /// are deliberately excluded from exports so a backup file is safe to share/store).
    func exportData() -> Data? {
        do {
            return try JSONEncoder().encode(endpoints)
        } catch {
            Self.logger.error("Failed to encode endpoints for export: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Merges by endpoint `id`: an imported endpoint whose id matches an existing one restores/
    /// overwrites it in place, anything else is added. Nothing already in the store is removed —
    /// importing is additive/restorative, never destructive, so a mis-chosen file can't itself
    /// cause data loss.
    func importEndpoints(from data: Data) throws {
        let imported = try JSONDecoder().decode([Endpoint].self, from: data).map(Self.normalizedEndpoint)
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
        do {
            let data = try JSONEncoder().encode(endpoints)
            defaults.set(data, forKey: Keys.endpoints)
        } catch {
            Self.logger.error("Failed to persist endpoints: \(error.localizedDescription, privacy: .public)")
        }
    }
}
