import Foundation
import OSLog

/// Persists a per-endpoint, per-day rollup of health checks — `totalChecks`/`downChecks`/
/// `downtimeSeconds` per calendar day — so the Stats tab can show a 30-day uptime history without
/// needing to retain weeks of raw `HealthCheckResult`s (see `HealthHistoryStore`, whose fixed-size
/// ring buffer of ~100 raw results covers only the last hour or two at typical check intervals).
/// Same persistence pattern as `HealthHistoryStore`: JSON file under Application Support, synchronous
/// atomic writes on every mutation.
@MainActor
final class DailyStatsStore: ObservableObject {
    static let retentionDays = 30
    private static let logger = Logger(subsystem: "com.zext.healthmonitor", category: "DailyStatsStore")
    /// Days kept beyond `retentionDays` before pruning, so a day that just scrolled out of the
    /// display window isn't deleted the moment it stops being shown.
    private static let pruneBufferDays = 5

    /// endpointId -> "yyyy-MM-dd" -> that day's rollup.
    @Published private(set) var stats: [UUID: [String: DailyStat]] = [:]

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
            self.fileURL = supportDir.appendingPathComponent("daily_stats.json")
        }
        load()
    }

    func record(endpointId: UUID, timestamp: Date, isHealthy: Bool, intervalSeconds: TimeInterval) {
        let day = Self.dayKey(for: timestamp)
        var endpointStats = stats[endpointId] ?? [:]
        var stat = endpointStats[day] ?? DailyStat()
        stat.totalChecks += 1
        if !isHealthy {
            stat.downChecks += 1
            stat.downtimeSeconds += intervalSeconds
        }
        endpointStats[day] = stat
        stats[endpointId] = endpointStats
        pruneOldDays(for: endpointId, referenceDate: timestamp)
        save()
    }

    /// Returns `days` entries ending on `referenceDate`'s day (oldest first). `stat` is `nil` for
    /// days with no recorded checks.
    func dailyStats(for endpointId: UUID, days: Int = retentionDays, referenceDate: Date = Date()) -> [(date: Date, stat: DailyStat?)] {
        let endpointStats = stats[endpointId] ?? [:]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        var results: [(date: Date, stat: DailyStat?)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            results.append((date, endpointStats[Self.dayKey(for: date)]))
        }
        return results
    }

    func removeStats(for endpointId: UUID) {
        stats.removeValue(forKey: endpointId)
        save()
    }

    private func pruneOldDays(for endpointId: UUID, referenceDate: Date) {
        guard var endpointStats = stats[endpointId] else { return }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays + Self.pruneBufferDays),
                                          to: calendar.startOfDay(for: referenceDate)) else { return }
        let cutoffKey = Self.dayKey(for: cutoff)
        endpointStats = endpointStats.filter { $0.key >= cutoffKey } // "yyyy-MM-dd" sorts lexicographically == chronologically
        stats[endpointId] = endpointStats
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
                return
            }
            Self.logger.error("Failed to read daily stats file: \(error.localizedDescription, privacy: .public)")
            return
        }

        let decoded: [String: [String: DailyStat]]
        do {
            decoded = try JSONDecoder().decode([String: [String: DailyStat]].self, from: data)
        } catch {
            Self.logger.error("Failed to decode daily stats file: \(error.localizedDescription, privacy: .public)")
            return
        }

        var result: [UUID: [String: DailyStat]] = [:]
        for (key, value) in decoded {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        stats = result
    }

    private func save() {
        var encodable: [String: [String: DailyStat]] = [:]
        for (key, value) in stats {
            encodable[key.uuidString] = value
        }
        do {
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save daily stats file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
