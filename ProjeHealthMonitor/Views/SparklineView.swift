import SwiftUI

struct SparklineView: View {
    let results: [HealthCheckResult]
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 1.5
    var height: CGFloat = 16

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(results) { result in
                let state = EndpointHealthState(result)
                // Degraded bars are shorter as well as orange, so they're distinguishable without color.
                RoundedRectangle(cornerRadius: 1)
                    .fill(state.color)
                    .frame(width: barWidth, height: state == .degraded ? height * 0.55 : height)
                    .help(tooltip(for: result))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryLabel)
    }

    private var summaryLabel: String {
        guard !results.isEmpty else { return "No check history yet" }
        let states = results.map(EndpointHealthState.init)
        let healthyCount = states.filter { $0 == .healthy }.count
        let degradedCount = states.filter { $0 == .degraded }.count
        let downCount = states.filter { $0 == .down }.count
        let degradedPart = degradedCount > 0 ? ", \(degradedCount) degraded" : ""
        return "History: \(results.count) checks, \(healthyCount) healthy\(degradedPart), \(downCount) down"
    }

    private func tooltip(for result: HealthCheckResult) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let status = EndpointHealthState(result).label.capitalized
        return "\(status) — \(formatter.string(from: result.timestamp))"
    }
}
