import SwiftUI

struct BackendEndpointRowView: View {
    let endpoint: DashboardEndpointInfo

    private static let isoFormatter = ISO8601DateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(dotColor)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(endpoint.name)
                    .font(.system(size: 13, weight: .medium))
                if let group = endpoint.groupName, !group.isEmpty {
                    Circle()
                        .fill(GroupBadgeStyle.color(for: group))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                if endpoint.isPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Response time bar (simple indicator instead of sparkline since we don't have history)
            if let check = endpoint.latestCheck, let ms = check.responseTimeMs {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(check.isHealthy ? Color.green : Color.red)
                        .frame(width: min(CGFloat(ms) / 5.0, 200), height: 4)
                    Text("\(ms)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 16)
            }

            HStack {
                if let uptime = endpoint.uptimePercent24h {
                    Text(String(format: "%.1f%% uptime (24h)", uptime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let incident = endpoint.activeIncident {
                    Label(incident.failureReason ?? "Incident active", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if let certDaysRemaining {
                    Label(certDaysRemaining >= 0 ? "SSL \(certDaysRemaining)d" : "SSL expired", systemImage: "lock.trianglebadge.exclamationmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var dotColor: Color {
        if endpoint.isPaused { return .gray }
        guard let check = endpoint.latestCheck else { return .gray }
        return check.isHealthy ? .green : .red
    }

    private var statusSymbolName: String {
        if endpoint.isPaused { return "pause.circle" }
        guard let check = endpoint.latestCheck else { return "circle.dotted" }
        return check.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var lastCheckedText: String {
        guard let check = endpoint.latestCheck,
              let date = Self.isoFormatter.date(from: check.timestamp) else {
            return "Not checked"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Days until certificate expiry, only when that expiry is within 14 days (including already
    /// expired). `nil` suppresses the SSL warning label entirely.
    private var certDaysRemaining: Int? {
        guard let certExpiry = endpoint.latestCheck?.certificateExpiresAt,
              let expiryDate = Self.isoFormatter.date(from: certExpiry) else {
            return nil
        }
        let days = Int(expiryDate.timeIntervalSinceNow / 86400)
        return days <= 14 ? days : nil
    }
}
