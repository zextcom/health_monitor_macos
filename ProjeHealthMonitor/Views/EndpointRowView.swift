import SwiftUI

struct EndpointRowView: View {
    let endpoint: Endpoint
    let results: [HealthCheckResult]

    private var lastResult: HealthCheckResult? { results.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(endpoint.name)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SparklineView(results: Array(results.suffix(30)))
        }
        .padding(.vertical, 6)
    }

    private var dotColor: Color {
        guard let lastResult else { return .gray }
        return lastResult.isHealthy ? .green : .red
    }

    private var lastCheckedText: String {
        guard let lastResult else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastResult.timestamp, relativeTo: Date())
    }
}
