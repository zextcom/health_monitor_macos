import SwiftUI

/// A status-page-style row of daily bars — one per day, colored by whether that day had any
/// downtime. Bigger sibling of `SparklineView` (which shows individual raw checks); this shows
/// `DailyStatsStore`'s day-level rollups instead, so it can cover weeks without needing raw history.
struct DailyUptimeBarView: View {
    let dailyStats: [(date: Date, stat: DailyStat?)]
    var barWidth: CGFloat = 6
    var spacing: CGFloat = 2
    var height: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(dailyStats, id: \.date) { entry in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: entry.stat))
                    .frame(width: barWidth, height: height)
                    .help(tooltip(for: entry))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryLabel)
    }

    private func color(for stat: DailyStat?) -> Color {
        guard let stat, stat.totalChecks > 0 else { return Color.secondary.opacity(0.2) }
        return stat.downChecks == 0 ? .green : .red
    }

    private func tooltip(for entry: (date: Date, stat: DailyStat?)) -> String {
        let dateText = Self.dayFormatter.string(from: entry.date)
        guard let stat = entry.stat, stat.totalChecks > 0 else { return "\(dateText) — no data" }
        guard stat.downChecks > 0 else { return "\(dateText) — healthy" }
        return "\(dateText) — down \(stat.downChecks)/\(stat.totalChecks) checks"
    }

    private var summaryLabel: String {
        let daysWithData = dailyStats.filter { ($0.stat?.totalChecks ?? 0) > 0 }
        guard !daysWithData.isEmpty else { return "No history yet" }
        let downDays = daysWithData.filter { ($0.stat?.downChecks ?? 0) > 0 }.count
        return "Last \(dailyStats.count) days: \(daysWithData.count) with data, \(downDays) had downtime"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
