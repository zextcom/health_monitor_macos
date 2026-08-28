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

enum CheckType: String, Codable, CaseIterable, Identifiable {
    case http
    case tcp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .tcp: return "TCP"
        }
    }
}

enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case exact
    case contains
    case regex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exact: return "Exact"
        case .contains: return "Contains"
        case .regex: return "Regex"
        }
    }
}

/// A single dot-path/expected-value check against the JSON response body. `Endpoint.jsonAssertions`
/// holds a list of these, ANDed together — every assertion must pass for the endpoint to be healthy.
struct JSONAssertion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Dot-path into the JSON response body, e.g. "data.status". Dictionary keys only, no array indices.
    var path: String
    /// Expected value at `path`, compared per `matchMode`.
    var expectedValue: String
    var matchMode: MatchMode = .exact

    init(id: UUID = UUID(), path: String, expectedValue: String, matchMode: MatchMode = .exact) {
        self.id = id
        self.path = path
        self.expectedValue = expectedValue
        self.matchMode = matchMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, expectedValue, matchMode
    }

    // Custom Codable (rather than synthesized) because `matchMode` was added after this struct
    // was already being persisted in `EndpointStore`/`UserDefaults` — synthesized Codable would
    // require the key on every stored assertion and break decoding of everyone's existing data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        expectedValue = try container.decode(String.self, forKey: .expectedValue)
        matchMode = try container.decodeIfPresent(MatchMode.self, forKey: .matchMode) ?? .exact
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(expectedValue, forKey: .expectedValue)
        try container.encode(matchMode, forKey: .matchMode)
    }
}

struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    /// `.tcp` endpoints reuse `url` as `tcp://host:port` rather than an HTTP target; status code,
    /// JSON assertions, and auth below are HTTP-only and unused for `.tcp`.
    var checkType: CheckType = .http
    var expectedStatusCode: Int = 200
    var checkIntervalOverride: TimeInterval?
    /// Optional display group used only for organizing endpoints in the UI.
    var groupName: String?

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

    init(id: UUID = UUID(), name: String, url: URL, checkType: CheckType = .http, expectedStatusCode: Int = 200,
         checkIntervalOverride: TimeInterval? = nil, groupName: String? = nil, jsonAssertions: [JSONAssertion] = [],
         authType: AuthType = .none, authUsername: String? = nil, authHeaderName: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.checkType = checkType
        self.expectedStatusCode = expectedStatusCode
        self.checkIntervalOverride = checkIntervalOverride
        self.groupName = groupName
        self.jsonAssertions = jsonAssertions
        self.authType = authType
        self.authUsername = authUsername
        self.authHeaderName = authHeaderName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, checkType, expectedStatusCode, checkIntervalOverride, groupName
        case jsonAssertions
        case jsonFieldPath, expectedFieldValue // legacy single-assertion schema, decode-only
        case authType, authUsername, authHeaderName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        checkType = try container.decodeIfPresent(CheckType.self, forKey: .checkType) ?? .http
        expectedStatusCode = try container.decodeIfPresent(Int.self, forKey: .expectedStatusCode) ?? 200
        checkIntervalOverride = try container.decodeIfPresent(TimeInterval.self, forKey: .checkIntervalOverride)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
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
        try container.encode(checkType, forKey: .checkType)
        try container.encode(expectedStatusCode, forKey: .expectedStatusCode)
        try container.encodeIfPresent(checkIntervalOverride, forKey: .checkIntervalOverride)
        try container.encodeIfPresent(groupName, forKey: .groupName)
        try container.encode(jsonAssertions, forKey: .jsonAssertions)
        try container.encode(authType, forKey: .authType)
        try container.encodeIfPresent(authUsername, forKey: .authUsername)
        try container.encodeIfPresent(authHeaderName, forKey: .authHeaderName)
    }
}
