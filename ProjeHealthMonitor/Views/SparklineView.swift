import SwiftUI

struct SparklineView: View {
    let results: [HealthCheckResult]
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 1.5
    var height: CGFloat = 16

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(results) { result in
                RoundedRectangle(cornerRadius: 1)
                    .fill(result.isHealthy ? Color.green : Color.red)
                    .frame(width: barWidth, height: height)
                    .help(tooltip(for: result))
            }
        }
        .frame(height: height)
    }

    private func tooltip(for result: HealthCheckResult) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let status = result.isHealthy ? "Healthy" : "Down"
        return "\(status) — \(formatter.string(from: result.timestamp))"
    }
}
