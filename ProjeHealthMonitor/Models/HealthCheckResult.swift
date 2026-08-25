import Foundation

struct HealthCheckResult: Codable, Identifiable, Equatable, Sendable {
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
