import Foundation
import OSLog

@MainActor
final class HealthHistoryStore: ObservableObject {
    nonisolated static let maxResultsPerEndpoint = 100
    private static let logger = Logger(subsystem: "com.zext.healthmonitor", category: "HealthHistoryStore")

    @Published private(set) var history: [UUID: [HealthCheckResult]] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProjeHealthMonitor", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create Application Support directory: \(error.localizedDescription, privacy: .public)")
            }
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
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
                return
            }
            Self.logger.error("Failed to read history file: \(error.localizedDescription, privacy: .public)")
            return
        }

        let decoded: [String: [HealthCheckResult]]
        do {
            decoded = try JSONDecoder().decode([String: [HealthCheckResult]].self, from: data)
        } catch {
            Self.logger.error("Failed to decode history file: \(error.localizedDescription, privacy: .public)")
            return
        }

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
        do {
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save history file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
