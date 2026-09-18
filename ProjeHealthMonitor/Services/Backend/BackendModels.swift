import Foundation

// MARK: - Auth

struct AuthUser: Codable, Sendable {
    let id: String
    let email: String
    let name: String
    let role: String
}

struct LoginResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: AuthUser
}

struct RefreshResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - Dashboard

struct DashboardSummary: Codable, Sendable {
    let totalEndpoints: Int
    let healthyEndpoints: Int
    let unhealthyEndpoints: Int
    let pausedEndpoints: Int
    let overallUptimePercent: Double
}

struct LatestCheckInfo: Codable, Sendable {
    let isHealthy: Bool
    let responseTimeMs: Int?
    let statusCode: Int?
    let failureReason: String?
    let timestamp: String
    let certificateExpiresAt: String?
}

struct ActiveIncidentInfo: Codable, Sendable {
    let startedAt: String
    let failureReason: String?
}

struct DashboardEndpointInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let checkType: String
    let groupName: String?
    let isPaused: Bool
    let latestCheck: LatestCheckInfo?
    let uptimePercent24h: Double?
    let activeIncident: ActiveIncidentInfo?
}

struct DashboardResponse: Codable, Sendable {
    let summary: DashboardSummary
    let endpoints: [DashboardEndpointInfo]
}

// MARK: - Backend Endpoint (full CRUD model)

struct BackendJsonAssertion: Codable, Sendable {
    let path: String
    let expectedValue: String
    let matchMode: String
}

struct BackendEndpoint: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let checkType: String
    let expectedStatusCode: Int
    let checkInterval: Int
    let groupName: String?
    let isPaused: Bool
    let jsonAssertions: [BackendJsonAssertion]
    let authType: String
    let authUsername: String?
    let authHeaderName: String?
    let createdAt: String?
    let updatedAt: String?
}
