import Foundation

@MainActor
final class HealthHistoryStore: ObservableObject {
    /// Hard backstop on top of the date-based retention `record(_:retentionDays:)` applies —
    /// guards against a pathological setting (e.g. a 1-second custom check interval combined with
    /// a 30-day retention window) ballooning memory/disk usage without bound. Not the primary
    /// retention mechanism — `EndpointStore.historyRetentionDays` is. `nonisolated` so it can be
    /// used as a default parameter value from a nonisolated context (e.g. test helpers).
    nonisolated static let defaultSafetyCapPerEndpoint = 20_000

    @Published private(set) var history: [UUID: [HealthCheckResult]] = [:]

    private let fileURL: URL
    private let safetyCapPerEndpoint: Int
    /// How long `record()` coalesces rapid successive writes before actually hitting disk — see
    /// `scheduleSave()`. `0` saves synchronously (used by tests that need to read back
    /// immediately via a second store instance).
    private let saveDebounceInterval: TimeInterval
    private var pendingSaveTask: Task<Void, Never>?

    init(fileURL: URL? = nil, saveDebounceInterval: TimeInterval = 5,
         safetyCapPerEndpoint: Int = HealthHistoryStore.defaultSafetyCapPerEndpoint) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProjeHealthMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.fileURL = supportDir.appendingPathComponent("history.json")
        }
        self.saveDebounceInterval = saveDebounceInterval
        self.safetyCapPerEndpoint = safetyCapPerEndpoint
        load()
    }

    func results(for endpointId: UUID) -> [HealthCheckResult] {
        history[endpointId] ?? []
    }

    func lastResult(for endpointId: UUID) -> HealthCheckResult? {
        history[endpointId]?.last
    }

    /// Appends `result`, then prunes anything older than `retentionDays` (see
    /// `EndpointStore.historyRetentionDays`) and — as a backstop — anything beyond
    /// `safetyCapPerEndpoint` regardless of age.
    func record(_ result: HealthCheckResult, retentionDays: Int) {
        var results = history[result.endpointId] ?? []
        results.append(result)

        let cutoff = result.timestamp.addingTimeInterval(-TimeInterval(retentionDays) * 86400)
        results.removeAll { $0.timestamp < cutoff }

        if results.count > safetyCapPerEndpoint {
            results.removeFirst(results.count - safetyCapPerEndpoint)
        }

        history[result.endpointId] = results
        scheduleSave()
    }

    func removeHistory(for endpointId: UUID) {
        history.removeValue(forKey: endpointId)
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = try? JSONDecoder().decode([String: [HealthCheckResult]].self, from: data)
        guard let decoded else { return }
        var result: [UUID: [HealthCheckResult]] = [:]
        for (key, value) in decoded {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        history = result
    }

    /// `save()` re-serializes and rewrites *every* endpoint's *entire* history on every call —
    /// fine at the old fixed ~100-record cap, but with day-scale retention a hot endpoint can mean
    /// megabytes rewritten every few seconds. Coalescing into at most one flush per
    /// `saveDebounceInterval` bounds that regardless of check frequency/endpoint count. Trades up
    /// to `saveDebounceInterval` seconds of the most recent results being lost on an abnormal
    /// quit — acceptable for monitoring telemetry (not user-authored data), matching this
    /// codebase's existing tolerance for approximation elsewhere (e.g. `DailyStat.downtimeSeconds`).
    private func scheduleSave() {
        guard saveDebounceInterval > 0 else {
            save()
            return
        }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self, saveDebounceInterval] in
            try? await Task.sleep(nanoseconds: UInt64(saveDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        var encodable: [String: [HealthCheckResult]] = [:]
        for (key, value) in history {
            encodable[key.uuidString] = value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
