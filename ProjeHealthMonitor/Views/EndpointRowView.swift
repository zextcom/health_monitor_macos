import SwiftUI

/// Deterministic, non-persisted color for a group name — same name always renders the same color,
/// without ever storing a color anywhere. Uses FNV-1a rather than `String.hashValue`: Swift
/// randomizes that seed per process launch, which would shuffle colors on every app restart.
/// Palette excludes green/red/orange — reserved for health status and cert-expiry warnings in the
/// same rows.
enum GroupBadgeStyle {
    static let palette: [Color] = [.blue, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan]

    static func color(for groupName: String) -> Color {
        palette[stableIndex(for: groupName)]
    }

    private static func stableIndex(for groupName: String) -> Int {
        let normalized = groupName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(palette.count))
    }
}

/// Small capsule showing a group name in its deterministic color — used for suggestion chips in
/// EndpointFormView.
struct GroupBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(GroupBadgeStyle.color(for: name).opacity(0.15))
            .foregroundStyle(GroupBadgeStyle.color(for: name))
            .clipShape(Capsule())
    }
}

struct EndpointRowView: View {
    let endpoint: Endpoint
    let results: [HealthCheckResult]

    private static let certWarningThresholdDays = 14

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
                if let group = endpoint.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                    Circle()
                        .fill(GroupBadgeStyle.color(for: group))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabelText)

            SparklineView(results: Array(results.suffix(30)))

            HStack {
                if let uptimeText {
                    Text(uptimeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let certWarningText {
                    Label(certWarningText, systemImage: "lock.trianglebadge.exclamationmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(certWarningText)
                }
            }
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

    private var accessibilityLabelText: String {
        var parts = [endpoint.name]
        if let group = endpoint.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            parts.append("group \(group)")
        }
        parts.append(statusDescription)
        parts.append(lastCheckedText)
        return parts.joined(separator: ", ")
    }

    private var lastCheckedText: String {
        guard let lastResult else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastResult.timestamp, relativeTo: Date())
    }

    private var uptimeText: String? {
        guard let percentage = HealthCheckService.uptimePercentage(results: results) else { return nil }
        return String(format: "%.1f%% uptime (last %d checks)", percentage, results.count)
    }

    private var certWarningText: String? {
        guard let expiry = lastResult?.certificateExpiresAt,
              HealthCheckService.isExpiringSoon(expiry, thresholdDays: Self.certWarningThresholdDays)
        else { return nil }
        let days = HealthCheckService.daysUntilExpiry(expiry)
        return days >= 0 ? "SSL expires in \(days)d" : "SSL expired"
    }
}
