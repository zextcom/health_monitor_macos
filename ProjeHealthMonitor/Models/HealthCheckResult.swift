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
    /// Health-standard endpoints only: up (`isHealthy`) but the service reported `warn`. Counts as
    /// healthy for uptime, incidents and daily stats; `failureReason` then holds the warn reason.
    let isDegraded: Bool

    init(id: UUID = UUID(), endpointId: UUID, timestamp: Date, isHealthy: Bool, responseTimeMs: Int?,
         statusCode: Int?, failureReason: String?, certificateExpiresAt: Date? = nil, isDegraded: Bool = false) {
        self.id = id
        self.endpointId = endpointId
        self.timestamp = timestamp
        self.isHealthy = isHealthy
        self.responseTimeMs = responseTimeMs
        self.statusCode = statusCode
        self.failureReason = failureReason
        self.certificateExpiresAt = certificateExpiresAt
        self.isDegraded = isHealthy && isDegraded
    }

    private enum CodingKeys: String, CodingKey {
        case id, endpointId, timestamp, isHealthy, responseTimeMs, statusCode, failureReason, certificateExpiresAt
        case isDegraded
    }

    // Custom decoding so history persisted before `isDegraded` existed still loads (same reason as
    // `Endpoint`'s decodeIfPresent fields). Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        endpointId = try container.decode(UUID.self, forKey: .endpointId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isHealthy = try container.decode(Bool.self, forKey: .isHealthy)
        responseTimeMs = try container.decodeIfPresent(Int.self, forKey: .responseTimeMs)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        certificateExpiresAt = try container.decodeIfPresent(Date.self, forKey: .certificateExpiresAt)
        isDegraded = try container.decodeIfPresent(Bool.self, forKey: .isDegraded) ?? false
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
