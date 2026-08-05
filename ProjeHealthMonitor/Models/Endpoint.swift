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

/// A single dot-path/expected-value check against the JSON response body. `Endpoint.jsonAssertions`
/// holds a list of these, ANDed together — every assertion must pass for the endpoint to be healthy.
struct JSONAssertion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Dot-path into the JSON response body, e.g. "data.status". Dictionary keys only, no array indices.
    var path: String
    /// Expected value at `path`, compared as a trimmed, case-insensitive string.
    var expectedValue: String
}

struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var expectedStatusCode: Int = 200
    var checkIntervalOverride: TimeInterval?

    /// Checks against the JSON response body, ANDed together. Empty means only the HTTP status
    /// code is checked.
    var jsonAssertions: [JSONAssertion] = []

    /// Non-secret auth configuration. The actual secret (bearer token, basic-auth password, or
    /// custom header value) is never stored here — `Endpoint` is persisted as plain JSON in
    /// `EndpointStore`/`UserDefaults`, so secrets live only in the Keychain via `SecretStore`,
    /// keyed by `id`.
    var authType: AuthType = .none
    /// Username for `.basicAuth` — not treated as secret.
    var authUsername: String?
    /// Header name for `.customHeader`, e.g. "X-API-Key" — not treated as secret.
    var authHeaderName: String?

    init(id: UUID = UUID(), name: String, url: URL, expectedStatusCode: Int = 200,
         checkIntervalOverride: TimeInterval? = nil, jsonAssertions: [JSONAssertion] = [],
         authType: AuthType = .none, authUsername: String? = nil, authHeaderName: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.expectedStatusCode = expectedStatusCode
        self.checkIntervalOverride = checkIntervalOverride
        self.jsonAssertions = jsonAssertions
        self.authType = authType
        self.authUsername = authUsername
        self.authHeaderName = authHeaderName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, expectedStatusCode, checkIntervalOverride
        case jsonAssertions
        case jsonFieldPath, expectedFieldValue // legacy single-assertion schema, decode-only
        case authType, authUsername, authHeaderName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        expectedStatusCode = try container.decodeIfPresent(Int.self, forKey: .expectedStatusCode) ?? 200
        checkIntervalOverride = try container.decodeIfPresent(TimeInterval.self, forKey: .checkIntervalOverride)
        authType = try container.decodeIfPresent(AuthType.self, forKey: .authType) ?? .none
        authUsername = try container.decodeIfPresent(String.self, forKey: .authUsername)
        authHeaderName = try container.decodeIfPresent(String.self, forKey: .authHeaderName)

        if let assertions = try container.decodeIfPresent([JSONAssertion].self, forKey: .jsonAssertions) {
            jsonAssertions = assertions
        } else if let legacyPath = try container.decodeIfPresent(String.self, forKey: .jsonFieldPath),
                  let legacyValue = try container.decodeIfPresent(String.self, forKey: .expectedFieldValue) {
            jsonAssertions = [JSONAssertion(path: legacyPath, expectedValue: legacyValue)]
        } else {
            jsonAssertions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(expectedStatusCode, forKey: .expectedStatusCode)
        try container.encodeIfPresent(checkIntervalOverride, forKey: .checkIntervalOverride)
        try container.encode(jsonAssertions, forKey: .jsonAssertions)
        try container.encode(authType, forKey: .authType)
        try container.encodeIfPresent(authUsername, forKey: .authUsername)
        try container.encodeIfPresent(authHeaderName, forKey: .authHeaderName)
    }
}
