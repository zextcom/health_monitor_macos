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
    /// Subset of `healthyEndpoints` reporting health-standard `warn`. Optional for older backends.
    let degradedEndpoints: Int?

    /// Menu bar status in backend mode: down > degraded > healthy.
    var overallStatus: HealthCheckService.OverallStatus {
        if totalEndpoints == 0 { return .unknown }
        if unhealthyEndpoints > 0 { return .down }
        return (degradedEndpoints ?? 0) > 0 ? .degraded : .healthy
    }
}

struct LatestCheckInfo: Codable, Sendable {
    let isHealthy: Bool
    let responseTimeMs: Int?
    let statusCode: Int?
    let failureReason: String?
    let timestamp: String
    let certificateExpiresAt: String?
    /// Health-standard `status` ("pass" / "warn" / "fail"); `nil` for other endpoints or older backends.
    let healthStatus: String?
    /// Up but reporting `warn`. Optional for older backends.
    let isDegraded: Bool?

    var healthState: EndpointHealthState {
        if !isHealthy { return .down }
        return isDegraded == true ? .degraded : .healthy
    }
}

struct ActiveIncidentInfo: Codable, Sendable {
    let startedAt: String
    let failureReason: String?
}

/// Backend's latest version check state for an endpoint (see backend `versionSummary`).
struct DashboardVersionInfo: Codable, Sendable {
    let isEnabled: Bool
    let current: String?
    let isFailing: Bool
    let failureReason: String?
    let lastCheckedAt: String?
    /// "versionCheck" or "healthStandard" (auto-tracked from the health response). Optional for older backends.
    let source: String?
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
    /// Optional so dashboards from a backend predating version checks still decode.
    let version: DashboardVersionInfo?
    /// Whether the endpoint uses the Zext Health Standard. Optional for older backends.
    let healthStandard: Bool?
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
