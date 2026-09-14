import Foundation

struct HealthCheckResult: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let endpointId: UUID
    let timestamp: Date
    let isHealthy: Bool
    let responseTimeMs: Int?
    let statusCode: Int?
    /// Short human-readable reason for a `down` result (timeout, network error, status mismatch, field mismatch).
    let failureReason: String?
    /// TLS certificate expiry for HTTPS endpoints, refreshed on a slower cadence than the health
    /// check itself (see `HealthCheckService`) and carried forward between refreshes. `var` since
    /// it's attached to an already-built result rather than computed inside `executeCheck`.
    var certificateExpiresAt: Date?

    init(id: UUID = UUID(), endpointId: UUID, timestamp: Date, isHealthy: Bool, responseTimeMs: Int?,
         statusCode: Int?, failureReason: String?, certificateExpiresAt: Date? = nil) {
        self.id = id
        self.endpointId = endpointId
        self.timestamp = timestamp
        self.isHealthy = isHealthy
        self.responseTimeMs = responseTimeMs
        self.statusCode = statusCode
        self.failureReason = failureReason
        self.certificateExpiresAt = certificateExpiresAt
    }
}

/// A single down period derived from a run of consecutive unhealthy `HealthCheckResult`s — see
/// `HealthCheckService.incidents(from:)`. Not persisted; recomputed from whatever raw history is
/// currently retained (`HealthHistoryStore`/`EndpointStore.historyRetentionDays`), so an incident
/// near either edge of that window may be incomplete — `startBoundaryUncertain`/`endedAt == nil`
/// flag that rather than silently presenting a guess as fact.
struct Incident: Identifiable, Equatable {
    var id: Date { startedAt }
    let startedAt: Date
    /// `nil` means the down run was still ongoing as of the most recent retained check — either
    /// truly ongoing, or the recovery simply fell outside the retention window.
    let endedAt: Date?
    /// `true` when this run starts at the very first retained result for the endpoint — the real
    /// start may be older than what's retained, so `startedAt` is a lower bound, not a fact.
    let startBoundaryUncertain: Bool
    let failureReason: String?
}
