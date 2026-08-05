import Foundation

enum AuthType: String, Codable, CaseIterable, Identifiable {
    case none
    case bearerToken
    case basicAuth
    case customHeader

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .bearerToken: return "Bearer Token"
        case .basicAuth: return "Basic Auth"
        case .customHeader: return "Custom Header"
        }
    }
}

struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var expectedStatusCode: Int = 200
    var checkIntervalOverride: TimeInterval?

    /// Dot-path into the JSON response body, e.g. "data.status". Dictionary keys only, no array indices.
    var jsonFieldPath: String?
    /// Expected value at `jsonFieldPath`, compared as a trimmed, case-insensitive string.
    var expectedFieldValue: String?

    /// Non-secret auth configuration. The actual secret (bearer token, basic-auth password, or
    /// custom header value) is never stored here — `Endpoint` is persisted as plain JSON in
    /// `EndpointStore`/`UserDefaults`, so secrets live only in the Keychain via `SecretStore`,
    /// keyed by `id`.
    var authType: AuthType = .none
    /// Username for `.basicAuth` — not treated as secret.
    var authUsername: String?
    /// Header name for `.customHeader`, e.g. "X-API-Key" — not treated as secret.
    var authHeaderName: String?
}
