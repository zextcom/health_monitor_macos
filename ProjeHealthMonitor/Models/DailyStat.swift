import Foundation

/// A single calendar day's aggregate of health checks for one endpoint. Kept deliberately small
/// (counts + a duration) rather than storing raw per-check history, so `DailyStatsStore` can retain
/// weeks of data without unbounded growth — unlike `HealthHistoryStore`'s fixed-size ring buffer of
/// raw results, which only covers the last ~100 checks.
struct DailyStat: Codable, Equatable, Sendable {
    var totalChecks: Int = 0
    var downChecks: Int = 0
    /// Approximated as `downChecks × effective check interval` at record time, not a measured
    /// outage window — simple and robust against gaps (app asleep/quit) rather than precise.
    var downtimeSeconds: TimeInterval = 0
}
