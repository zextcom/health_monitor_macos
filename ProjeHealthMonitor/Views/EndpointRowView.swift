import SwiftUI

struct EndpointRowView: View {
    let endpoint: Endpoint
    let results: [HealthCheckResult]

    private var lastResult: HealthCheckResult? { results.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(dotColor)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(endpoint.name)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(endpoint.name), \(statusDescription), \(lastCheckedText)")

            SparklineView(results: Array(results.suffix(30)))
        }
        .padding(.vertical, 6)
    }

    private var dotColor: Color {
        guard let lastResult else { return .gray }
        return lastResult.isHealthy ? .green : .red
    }

    /// Shape differs per status, not just color, so the indicator reads correctly for color-blind users.
    private var statusSymbolName: String {
        guard let lastResult else { return "circle.dotted" }
        return lastResult.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusDescription: String {
        guard let lastResult else { return "no data yet" }
        return lastResult.isHealthy ? "healthy" : "down"
    }

    private var lastCheckedText: String {
        guard let lastResult else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastResult.timestamp, relativeTo: Date())
    }
}
