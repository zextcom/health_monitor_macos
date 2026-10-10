import SwiftUI

/// Compact "v1.5.0" capsule for endpoint rows (local and backend). Orange with a warning glyph when
/// the latest version check failed — orange rather than red since a version failure never means
/// the endpoint itself is down (red stays reserved for health status).
struct VersionBadge: View {
    let version: String?
    let isFailing: Bool
    let failureReason: String?

    /// Prefixes a bare "1.5.0" with "v" but leaves "v1.5.0"/"V2" or non-numeric values (commit
    /// hashes, "main-abc123") alone. Truncates very long values (e.g. full SHAs) to keep rows tidy.
    /// `nonisolated`: `View` is `@MainActor` on older SDKs, which would otherwise make this pure
    /// helper main-actor-bound too.
    nonisolated static func displayText(for version: String, maxLength: Int = 14) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixed = trimmed.first?.isNumber == true ? "v\(trimmed)" : trimmed
        guard prefixed.count > maxLength else { return prefixed }
        return String(prefixed.prefix(maxLength - 1)) + "…"
    }

    var body: some View {
        if version != nil || isFailing {
            HStack(spacing: 3) {
                if isFailing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                Text(version.map { Self.displayText(for: $0) } ?? "version")
                    .font(.system(.caption2, design: .monospaced))
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((isFailing ? Color.orange : Color.secondary).opacity(0.15))
            .foregroundStyle(isFailing ? Color.orange : Color.secondary)
            .clipShape(Capsule())
            .help(isFailing ? "Version check failed: \(failureReason ?? "unknown error")" : "Current version")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        let versionText = version.map { "version \($0)" } ?? "version unknown"
        return isFailing ? "\(versionText), version check failed: \(failureReason ?? "unknown error")" : versionText
    }
}
