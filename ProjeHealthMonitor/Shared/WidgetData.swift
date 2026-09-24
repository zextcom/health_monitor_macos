import Foundation

/// Lightweight snapshot of a single endpoint's health, shared between the main app and the widget
/// extension via App Group `UserDefaults`. Deliberately free of any WidgetKit or AppKit imports so
/// both targets can compile it.
struct WidgetEndpointStatus: Codable, Sendable {
    let name: String
    let url: String
    let isHealthy: Bool
    let responseTimeMs: Int?
    let lastCheckedAt: Date?
    let group: String?
}

/// Top-level container written by the main app and read by the widget's `TimelineProvider`.
struct WidgetDashboard: Codable, Sendable {
    let endpoints: [WidgetEndpointStatus]
    let updatedAt: Date

    /// App Group suite name shared between the main app and the widget extension.
    static let suiteName = "group.com.zext.healthmonitor"
    /// `UserDefaults` key under which the JSON-encoded `WidgetDashboard` is stored.
    static let userDefaultsKey = "widgetDashboard"
}
