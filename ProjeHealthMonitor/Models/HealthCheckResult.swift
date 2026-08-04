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
}
