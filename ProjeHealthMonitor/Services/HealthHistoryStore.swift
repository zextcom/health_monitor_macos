import Foundation

@MainActor
final class HealthHistoryStore: ObservableObject {
    static let maxResultsPerEndpoint = 100

    @Published private(set) var history: [UUID: [HealthCheckResult]] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProjeHealthMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            self.fileURL = supportDir.appendingPathComponent("history.json")
        }
        load()
    }

    func results(for endpointId: UUID) -> [HealthCheckResult] {
        history[endpointId] ?? []
    }

    func lastResult(for endpointId: UUID) -> HealthCheckResult? {
        history[endpointId]?.last
    }

    func record(_ result: HealthCheckResult) {
        var results = history[result.endpointId] ?? []
        results.append(result)
        if results.count > Self.maxResultsPerEndpoint {
            results.removeFirst(results.count - Self.maxResultsPerEndpoint)
        }
        history[result.endpointId] = results
        save()
    }

    func removeHistory(for endpointId: UUID) {
        history.removeValue(forKey: endpointId)
        save()
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

    private func save() {
        var encodable: [String: [HealthCheckResult]] = [:]
        for (key, value) in history {
            encodable[key.uuidString] = value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
