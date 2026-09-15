import Foundation

/// Narrow seam over `NSUbiquitousKeyValueStore` — exposes only what `EndpointStore` needs, so
/// tests can substitute a fake instead of depending on a real (network-backed,
/// iCloud-account-dependent) key-value store.
protocol UbiquitousKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

@MainActor
final class EndpointStore: ObservableObject {
    /// Days a retained-deleted endpoint's history/stats survive before being purged if never
    /// reused (see `HealthCheckService.isRetainedRecordExpired`). Mirrors
    /// `DailyStatsStore.retentionDays`'s existing convention. `nonisolated` — it's a plain
    /// constant, and `HealthCheckService.isRetainedRecordExpired` (a `nonisolated static func`)
    /// needs to reference it as a default parameter value.
    nonisolated static let retainedDataExpiryDays = 30

    private enum Keys {
        static let endpoints = "endpoints"
        static let retainedDeletedEndpoints = "retainedDeletedEndpoints"
        static let globalCheckInterval = "globalCheckInterval"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnRecovery = "notifyOnRecovery"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let requestTimeout = "requestTimeout"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let historyRetentionDays = "historyRetentionDays"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let lastSyncedModifiedAt = "lastSyncedModifiedAt"
    }

    /// Key inside the iCloud key-value store (not a `UserDefaults` key) — namespaced since the
    /// store is shared across every app the user has opted into this same iCloud account for.
    private static let ubiquitousSyncKey = "com.zext.healthmonitor.endpointsSync"

    private struct SyncPayload: Codable {
        let endpoints: [Endpoint]
        let modifiedAt: Date
    }

    @Published var endpoints: [Endpoint] {
        didSet { persistEndpoints() }
    }
    /// Endpoints deleted with their history explicitly kept — see `removeEndpoint(id:retainData:)`.
    @Published private(set) var retainedDeletedEndpoints: [RetainedEndpointRecord] {
        didSet { persistRetainedEndpoints() }
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
    /// How many days of raw per-check history `HealthHistoryStore` keeps before pruning (see
    /// `HealthHistoryStore.record(_:retentionDays:)`).
    @Published var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays) }
    }
    /// Set once the app has auto-opened Settings on first launch, so returning users who clear
    /// their endpoint list don't get it reopened on every launch.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }
    /// Opt-in: mirrors `endpoints` through iCloud's key-value store so the same list can be used
    /// across the user's own Macs. Off by default — enabling it for the first time pulls down
    /// whatever's already synced (if newer) before pushing the local list up.
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            guard iCloudSyncEnabled, !isLoading else { return }
            applyRemoteSyncPayloadIfNewer()
            pushEndpointsToICloud()
        }
    }

    private let defaults: UserDefaults
    private let ubiquitousStore: UbiquitousKeyValueStoring
    /// `nonisolated(unsafe)`: only ever mutated on the main actor (assigned once, at the end of
    /// `init`), but `deinit` itself runs nonisolated, and `NSObjectProtocol` isn't `Sendable`.
    nonisolated(unsafe) private var ubiquitousStoreObserver: NSObjectProtocol?
    /// Guards `pushEndpointsToICloud()` from re-pushing a payload we just pulled down — without
    /// this, two synced Macs would keep re-triggering each other's external-change notification.
    private var isApplyingRemoteSyncPayload = false
    /// Guards `persistEndpoints()` from running as a side effect of the `didSet` firing during
    /// `init`'s own assignment — without this, a decode failure on existing data would
    /// immediately overwrite it on disk with an empty array before we ever hand control back.
    private var isLoading = true

    init(defaults: UserDefaults = .standard, ubiquitousStore: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default) {
        self.defaults = defaults
        self.ubiquitousStore = ubiquitousStore

        if let data = defaults.data(forKey: Keys.endpoints),
           let decoded = try? JSONDecoder().decode([Endpoint].self, from: data) {
            self.endpoints = decoded
        } else {
            self.endpoints = []
        }

        if let data = defaults.data(forKey: Keys.retainedDeletedEndpoints),
           let decoded = try? JSONDecoder().decode([RetainedEndpointRecord].self, from: data) {
            self.retainedDeletedEndpoints = decoded
        } else {
            self.retainedDeletedEndpoints = []
        }

        let storedInterval = defaults.double(forKey: Keys.globalCheckInterval)
        self.globalCheckInterval = storedInterval > 0 ? storedInterval : 60

        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.notifyOnRecovery = defaults.object(forKey: Keys.notifyOnRecovery) as? Bool ?? true
        self.launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? false

        let storedTimeout = defaults.double(forKey: Keys.requestTimeout)
        self.requestTimeout = storedTimeout > 0 ? storedTimeout : 10

        let storedRetentionDays = defaults.integer(forKey: Keys.historyRetentionDays)
        self.historyRetentionDays = storedRetentionDays > 0 ? storedRetentionDays : 7

        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false
        self.iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool ?? false

        isLoading = false

        if self.iCloudSyncEnabled {
            applyRemoteSyncPayloadIfNewer()
        }
        ubiquitousStoreObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyRemoteSyncPayloadIfNewer()
            }
        }
    }

    deinit {
        if let ubiquitousStoreObserver {
            NotificationCenter.default.removeObserver(ubiquitousStoreObserver)
        }
    }

    func addEndpoint(_ endpoint: Endpoint) {
        endpoints.append(endpoint)
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
    }

    /// Removes the endpoint. If `retainData` is true, its history/stats aren't touched here —
    /// the caller is expected to leave `HealthHistoryStore`/`DailyStatsStore` alone — and a
    /// `RetainedEndpointRecord` is kept so `matchingRetainedEndpoint(forURL:)` can find it again;
    /// it's purged automatically after `retainedDataExpiryDays` if never reused (see
    /// `HealthCheckService.isRetainedRecordExpired`).
    func removeEndpoint(id: UUID, retainData: Bool) {
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { return }
        endpoints.removeAll { $0.id == id }
        if retainData {
            retainedDeletedEndpoints.append(RetainedEndpointRecord(id: id, name: endpoint.name, url: endpoint.url, deletedAt: Date()))
        }
    }

    /// First retained-deleted endpoint whose URL matches (case-insensitive), for surfacing
    /// "previous history found" in the add-endpoint form. Two different deleted endpoints
    /// coincidentally sharing a URL is an accepted edge case — first match wins.
    func matchingRetainedEndpoint(forURL url: URL) -> RetainedEndpointRecord? {
        retainedDeletedEndpoints.first { $0.url.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }
    }

    /// Clears a retained record once its history/stats are reattached to a newly-saved endpoint —
    /// bookkeeping only, the underlying history/stats are left alone (they're "live" again).
    func reclaimRetainedEndpoint(id: UUID) {
        retainedDeletedEndpoints.removeAll { $0.id == id }
    }

    /// Same removal as `reclaimRetainedEndpoint`, used instead by the expiry sweep (see
    /// `HealthCheckService`) when a retained record's data is being purged, not reattached.
    func removeRetainedEndpointRecord(id: UUID) {
        retainedDeletedEndpoints.removeAll { $0.id == id }
    }

    /// Distinct group names currently in use, trimmed, blanks excluded, sorted case-insensitively.
    /// Recomputed from `endpoints` on every access — no separate persisted groups list, since
    /// groups are free text with no management screen. A typo'd group name can only be fixed by
    /// editing each affected endpoint individually — deferred intentionally, see ROADMAP.local.md.
    var allGroups: [String] {
        let names = endpoints
            .compactMap { $0.group?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        pushEndpointsToICloud()
    }

    private func persistRetainedEndpoints() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(retainedDeletedEndpoints) else { return }
        defaults.set(data, forKey: Keys.retainedDeletedEndpoints)
    }

    // MARK: - iCloud sync

    private func pushEndpointsToICloud() {
        guard iCloudSyncEnabled, !isApplyingRemoteSyncPayload else { return }
        let payload = SyncPayload(endpoints: endpoints, modifiedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        ubiquitousStore.set(data, forKey: Self.ubiquitousSyncKey)
        defaults.set(payload.modifiedAt, forKey: Keys.lastSyncedModifiedAt)
    }

    /// Applies the remote endpoint list only if it's newer than the last payload we pushed or
    /// applied — `nil` (never synced before on this Mac) counts as "always apply", so enabling
    /// sync for the first time on a second Mac pulls down whatever the first Mac already pushed.
    func applyRemoteSyncPayloadIfNewer() {
        guard iCloudSyncEnabled else { return }
        guard let data = ubiquitousStore.data(forKey: Self.ubiquitousSyncKey),
              let payload = try? JSONDecoder().decode(SyncPayload.self, from: data)
        else { return }

        let lastKnown = defaults.object(forKey: Keys.lastSyncedModifiedAt) as? Date
        guard lastKnown == nil || payload.modifiedAt > lastKnown! else { return }

        isApplyingRemoteSyncPayload = true
        endpoints = payload.endpoints
        isApplyingRemoteSyncPayload = false
        defaults.set(payload.modifiedAt, forKey: Keys.lastSyncedModifiedAt)
    }
}
