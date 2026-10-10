import Foundation

/// Persists each endpoint's latest version check result plus a capped timeline of distinct
/// versions seen (see `EndpointVersionState`). Writes are tiny and happen only every N health
/// checks, so unlike `HealthHistoryStore` there's no save debouncing.
@MainActor
final class VersionStore: ObservableObject {
    nonisolated static let historyLimit = 50

    @Published private(set) var states: [UUID: EndpointVersionState] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProjeHealthMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.fileURL = supportDir.appendingPathComponent("versions.json")
        }
        load()
    }

    func state(for endpointId: UUID) -> EndpointVersionState? {
        states[endpointId]
    }

    /// Records `result` and returns the transitions worth notifying about.
    @discardableResult
    func record(_ result: VersionCheckResult, for endpointId: UUID) -> [VersionCheckEvent] {
        let (newState, events) = Self.apply(result, to: states[endpointId])
        states[endpointId] = newState
        save()
        return events
    }

    func removeState(for endpointId: UUID) {
        guard states.removeValue(forKey: endpointId) != nil else { return }
        save()
    }

    /// Pure transition logic, kept static so it's testable without touching disk.
    ///
    /// - Failure/recovery events fire only on a transition between two known results, mirroring
    ///   down/recovered for health checks — the very first result never notifies.
    /// - A change is detected against the last *observed* version (from history), not the last
    ///   result — so a deploy that briefly fails and comes back on a new version still reports it.
    /// - The first observed version never counts as a change.
    nonisolated static func apply(_ result: VersionCheckResult, to previous: EndpointVersionState?,
                                  historyLimit: Int = VersionStore.historyLimit) -> (EndpointVersionState, [VersionCheckEvent]) {
        var state = previous ?? EndpointVersionState()
        var events: [VersionCheckEvent] = []

        if let previousResult = state.lastResult {
            if previousResult.isSuccess, !result.isSuccess {
                events.append(.failed(reason: result.failureReason ?? "Version check failed"))
            } else if !previousResult.isSuccess, result.isSuccess {
                events.append(.recovered)
            }
        }

        if let observed = result.version?.trimmingCharacters(in: .whitespacesAndNewlines), !observed.isEmpty {
            if let last = state.history.last, last.value == observed {
                state.history[state.history.count - 1].lastSeenAt = result.timestamp
            } else {
                if let last = state.history.last {
                    events.append(.changed(from: last.value, to: observed))
                }
                state.history.append(VersionHistoryEntry(value: observed, firstSeenAt: result.timestamp,
                                                         lastSeenAt: result.timestamp))
                if state.history.count > historyLimit {
                    state.history.removeFirst(state.history.count - historyLimit)
                }
            }
        }

        state.lastResult = result
        return (state, events)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: EndpointVersionState].self, from: data) else { return }
        var result: [UUID: EndpointVersionState] = [:]
        for (key, value) in decoded {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        states = result
    }

    private func save() {
        var encodable: [String: EndpointVersionState] = [:]
        for (key, value) in states {
            encodable[key.uuidString] = value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
