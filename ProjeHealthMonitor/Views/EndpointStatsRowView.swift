import SwiftUI

struct EndpointStatsRowView: View {
    let endpoint: Endpoint
    let dailyStats: [(date: Date, stat: DailyStat?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(endpoint.name)
                    .font(.headline)
                Spacer()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DailyUptimeBarView(dailyStats: dailyStats)
        }
        .padding(.vertical, 4)
    }

    private var summaryText: String {
        let statsWithData = dailyStats.compactMap(\.stat).filter { $0.totalChecks > 0 }
        guard !statsWithData.isEmpty else { return "No data yet" }

        let totalChecks = statsWithData.reduce(0) { $0 + $1.totalChecks }
        let downChecks = statsWithData.reduce(0) { $0 + $1.downChecks }
        let downtimeSeconds = statsWithData.reduce(0) { $0 + $1.downtimeSeconds }

        let uptimePercent = Double(totalChecks - downChecks) / Double(totalChecks) * 100
        let uptimeText = String(format: "%.1f%% uptime", uptimePercent)

        guard downtimeSeconds > 0 else { return uptimeText }
        return "\(uptimeText) · \(Self.durationFormatter.string(from: downtimeSeconds) ?? "0m") down"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
