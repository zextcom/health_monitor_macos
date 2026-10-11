import Foundation

/// Lightweight snapshot of a single endpoint's health, shared between the main app and the widget
/// extension via App Group `UserDefaults`. Deliberately free of any WidgetKit or AppKit imports so
/// both targets can compile it.
struct WidgetEndpointStatus: Codable, Sendable {
    let name: String
    let url: String
    let isHealthy: Bool
    /// Up but reporting `warn` (Zext Health Standard). Only meaningful when `isHealthy` is true.
    let isDegraded: Bool
    let responseTimeMs: Int?
    let lastCheckedAt: Date?
    let group: String?

    init(name: String, url: String, isHealthy: Bool, isDegraded: Bool = false, responseTimeMs: Int?,
         lastCheckedAt: Date?, group: String?) {
        self.name = name
        self.url = url
        self.isHealthy = isHealthy
        self.isDegraded = isDegraded
        self.responseTimeMs = responseTimeMs
        self.lastCheckedAt = lastCheckedAt
        self.group = group
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, isHealthy, isDegraded, responseTimeMs, lastCheckedAt, group
    }

    // `isDegraded` is decodeIfPresent: an updated widget may read a snapshot written by an older app.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        isHealthy = try container.decode(Bool.self, forKey: .isHealthy)
        isDegraded = try container.decodeIfPresent(Bool.self, forKey: .isDegraded) ?? false
        responseTimeMs = try container.decodeIfPresent(Int.self, forKey: .responseTimeMs)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        group = try container.decodeIfPresent(String.self, forKey: .group)
    }

    var state: WidgetHealthState {
        guard isHealthy else { return .down }
        return isDegraded ? .degraded : .healthy
    }
}

/// Healthy/degraded/down for the widget. Mirrors the app's `EndpointHealthState` (which the widget
/// target can't see) including its SF Symbols — shape differs per state, not just color.
enum WidgetHealthState: Equatable, Sendable {
    case healthy, degraded, down

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .down: return "exclamationmark.circle.fill"
        }
    }
}

/// Counts and headline for the widget, kept pure so the main app's tests can cover it.
struct WidgetSummary: Equatable, Sendable {
    let total: Int
    let healthy: Int
    let degraded: Int
    let down: Int

    init(endpoints: [WidgetEndpointStatus]) {
        total = endpoints.count
        healthy = endpoints.filter { $0.state == .healthy }.count
        degraded = endpoints.filter { $0.state == .degraded }.count
        down = endpoints.filter { $0.state == .down }.count
    }

    /// Worst state wins: any down → down, else any degraded → degraded, else healthy.
    var overallState: WidgetHealthState {
        if down > 0 { return .down }
        if degraded > 0 { return .degraded }
        return .healthy
    }

    /// e.g. "3/3 Healthy", "1/3 Degraded", "1/3 Down", "1/3 Down · 1 Degraded".
    var headline: String {
        switch overallState {
        case .healthy: return "\(total)/\(total) Healthy"
        case .degraded: return "\(degraded)/\(total) Degraded"
        case .down: return degraded > 0 ? "\(down)/\(total) Down · \(degraded) Degraded" : "\(down)/\(total) Down"
        }
    }
}

/// Top-level container written by the main app and read by the widget's `TimelineProvider`.
struct WidgetDashboard: Codable, Sendable {
    let endpoints: [WidgetEndpointStatus]
    let updatedAt: Date

    /// App Group suite name shared between the main app and the widget extension. Team-ID
    /// prefixed (macOS style) rather than `group.`-prefixed (iOS style): for this Developer ID
    /// distributed app, a `group.` App Group needs a provisioning profile, which Manual Release
    /// signing on CI doesn't have — the Team ID prefix is authorized by the signature alone.
    /// Must match `com.apple.security.application-groups` in both targets' entitlements.
    static let suiteName = "4MSY72K4VX.com.zext.healthmonitor"
    /// `UserDefaults` key under which the JSON-encoded `WidgetDashboard` is stored.
    static let userDefaultsKey = "widgetDashboard"
}
