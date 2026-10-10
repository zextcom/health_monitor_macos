import Foundation

/// Optional secondary check attached to an `Endpoint`: every `everyNChecks` health checks, fetch
/// JSON from a separate `url`, read the value at `versionFieldPath`, and evaluate `assertions`
/// against the same body. Never affects the endpoint's own health/uptime — a failure only surfaces
/// as a version warning (see `VersionStore`/`HealthCheckService.executeVersionCheck`).
///
/// Auth is independent from the endpoint's own auth (the version URL may live on a different host
/// with different credentials). As with `Endpoint`, the secret itself never lives here — it's in
/// the Keychain under `secretAccount(for:)`.
struct VersionCheckConfig: Codable, Equatable {
    static let defaultEveryNChecks = 5

    /// Disabling keeps the rest of the config so re-enabling doesn't mean retyping everything.
    var isEnabled: Bool = true
    var url: URL
    var everyNChecks: Int = VersionCheckConfig.defaultEveryNChecks
    /// Dot-path to the version string in the JSON body, e.g. "data.version". Same path syntax as
    /// `JSONAssertion.path`.
    var versionFieldPath: String
    /// Extra checks against the same body, ANDed — same semantics as `Endpoint.jsonAssertions`.
    var assertions: [JSONAssertion] = []
    var authType: AuthType = .none
    var authUsername: String?
    var authHeaderName: String?

    init(isEnabled: Bool = true, url: URL, everyNChecks: Int = VersionCheckConfig.defaultEveryNChecks,
         versionFieldPath: String, assertions: [JSONAssertion] = [], authType: AuthType = .none,
         authUsername: String? = nil, authHeaderName: String? = nil) {
        self.isEnabled = isEnabled
        self.url = url
        self.everyNChecks = everyNChecks
        self.versionFieldPath = versionFieldPath
        self.assertions = assertions
        self.authType = authType
        self.authUsername = authUsername
        self.authHeaderName = authHeaderName
    }

    /// Keychain account for the version check's own secret — distinct from the endpoint's
    /// `id.uuidString` account so the two never overwrite each other.
    static func secretAccount(for endpointId: UUID) -> String {
        "\(endpointId.uuidString).version"
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, url, everyNChecks, versionFieldPath, assertions, authType, authUsername, authHeaderName
    }

    // Custom decoding (decodeIfPresent everywhere but the essentials) for the same reason as
    // `Endpoint`/`JSONAssertion`: fields added later must not break decoding of persisted data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        url = try container.decode(URL.self, forKey: .url)
        everyNChecks = max(1, try container.decodeIfPresent(Int.self, forKey: .everyNChecks) ?? Self.defaultEveryNChecks)
        versionFieldPath = try container.decodeIfPresent(String.self, forKey: .versionFieldPath) ?? ""
        assertions = try container.decodeIfPresent([JSONAssertion].self, forKey: .assertions) ?? []
        authType = try container.decodeIfPresent(AuthType.self, forKey: .authType) ?? .none
        authUsername = try container.decodeIfPresent(String.self, forKey: .authUsername)
        authHeaderName = try container.decodeIfPresent(String.self, forKey: .authHeaderName)
    }
}

/// Outcome of one version check run. `version` is set whenever the field could be read — even if
/// an assertion then failed — since the observed version is still a fact worth tracking.
struct VersionCheckResult: Codable, Equatable {
    let timestamp: Date
    let isSuccess: Bool
    let version: String?
    let failureReason: String?
    let responseTimeMs: Int?
    let statusCode: Int?
}

/// One distinct version observed over time — consecutive results with the same value collapse into
/// a single entry, so the history reads as a deploy timeline rather than a raw check log.
struct VersionHistoryEntry: Codable, Equatable, Identifiable {
    var id: Date { firstSeenAt }
    let value: String
    let firstSeenAt: Date
    var lastSeenAt: Date
}

/// Everything persisted per endpoint by `VersionStore`.
struct EndpointVersionState: Codable, Equatable {
    var lastResult: VersionCheckResult?
    /// Oldest first, capped at `VersionStore.historyLimit`.
    var history: [VersionHistoryEntry] = []

    /// Most recently observed version (from history, so a later failed run doesn't hide it).
    var currentVersion: String? { history.last?.value }
    var isFailing: Bool { lastResult?.isSuccess == false }
}

/// Notification-worthy transitions produced by `VersionStore.apply(_:to:)`.
enum VersionCheckEvent: Equatable {
    case changed(from: String, to: String)
    case failed(reason: String)
    case recovered
}

/// Editable, string-backed form state for the "Advanced → Version check" panel, with the
/// validation/secret rules kept here (pure, unit-tested) rather than inside `EndpointFormView`.
struct VersionCheckDraft: Equatable {
    var isEnabled = false
    var urlString = ""
    var everyNChecks = String(VersionCheckConfig.defaultEveryNChecks)
    var versionFieldPath = ""
    var assertions: [JSONAssertion] = []
    var authType: AuthType = .none
    var authUsername = ""
    var authHeaderName = ""
    /// Never prefilled from the Keychain — blank on edit means "keep the existing secret".
    var secret = ""

    static let maxEveryNChecks = 1000

    init() {}

    init(config: VersionCheckConfig?) {
        guard let config else { return }
        isEnabled = config.isEnabled
        urlString = config.url.absoluteString
        everyNChecks = String(config.everyNChecks)
        versionFieldPath = config.versionFieldPath
        assertions = config.assertions
        authType = config.authType
        authUsername = config.authUsername ?? ""
        authHeaderName = config.authHeaderName ?? ""
    }

    struct Output: Equatable {
        let config: VersionCheckConfig?
        let secretUpdate: SecretUpdate
    }

    var parsedURL: URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Best-effort config for the "Test" button — no secret/N validation, just what's needed to fire
    /// a request and evaluate it.
    var testConfig: VersionCheckConfig? {
        guard let url = parsedURL else { return nil }
        return VersionCheckConfig(url: url, versionFieldPath: versionFieldPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                  assertions: JSONAssertion.cleaned(assertions) ?? [], authType: authType,
                                  authUsername: authUsername, authHeaderName: authHeaderName)
    }

    /// Validates the draft against the endpoint's previously saved config (`nil` in add mode).
    /// - Disabled: kept as a paused config if the URL still parses (so re-enabling is painless),
    ///   otherwise dropped entirely along with its secret. Disabled drafts are never rejected.
    /// - Enabled: every field must be valid, and a secret is required unless an existing one of the
    ///   same auth type can be kept.
    func validate(original: VersionCheckConfig?) -> Result<Output, VersionCheckDraftError> {
        let originalHadSecret = (original?.authType ?? .none) != .none
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isEnabled else {
            guard let url = parsedURL else {
                return .success(Output(config: nil, secretUpdate: originalHadSecret ? .cleared : .unchanged))
            }
            let config = VersionCheckConfig(
                isEnabled: false, url: url,
                everyNChecks: Int(everyNChecks.trimmingCharacters(in: .whitespaces)).map { min(max($0, 1), Self.maxEveryNChecks) }
                    ?? VersionCheckConfig.defaultEveryNChecks,
                versionFieldPath: versionFieldPath.trimmingCharacters(in: .whitespacesAndNewlines),
                // Half-filled rows are dropped rather than rejected — a paused config is never blocking.
                assertions: assertions.compactMap { JSONAssertion.cleaned([$0])?.first },
                authType: authType, authUsername: trimmedUsername, authHeaderName: trimmedHeaderName)
            let secretUpdate: SecretUpdate
            if authType == .none {
                secretUpdate = originalHadSecret ? .cleared : .unchanged
            } else {
                secretUpdate = trimmedSecret.isEmpty ? .unchanged : .set(trimmedSecret)
            }
            return .success(Output(config: config, secretUpdate: secretUpdate))
        }

        guard let url = parsedURL else { return .failure(.invalidURL) }
        guard let everyN = Int(everyNChecks.trimmingCharacters(in: .whitespaces)), (1...Self.maxEveryNChecks).contains(everyN) else {
            return .failure(.invalidFrequency)
        }
        let path = versionFieldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .failure(.missingVersionField) }
        guard let cleanedAssertions = JSONAssertion.cleaned(assertions) else { return .failure(.incompleteAssertion) }
        if authType == .customHeader, trimmedHeaderName == nil { return .failure(.missingHeaderName) }

        let secretUpdate: SecretUpdate
        if authType == .none {
            secretUpdate = originalHadSecret ? .cleared : .unchanged
        } else if !trimmedSecret.isEmpty {
            secretUpdate = .set(trimmedSecret)
        } else if original?.authType != authType {
            return .failure(.missingSecret(authType))
        } else {
            secretUpdate = .unchanged
        }

        let config = VersionCheckConfig(isEnabled: true, url: url, everyNChecks: everyN, versionFieldPath: path,
                                        assertions: cleanedAssertions, authType: authType,
                                        authUsername: authType == .basicAuth ? trimmedUsername : nil,
                                        authHeaderName: authType == .customHeader ? trimmedHeaderName : nil)
        return .success(Output(config: config, secretUpdate: secretUpdate))
    }

    private var trimmedUsername: String? {
        let value = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var trimmedHeaderName: String? {
        let value = authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum VersionCheckDraftError: Error, Equatable {
    case invalidURL
    case invalidFrequency
    case missingVersionField
    case incompleteAssertion
    case missingHeaderName
    case missingSecret(AuthType)

    var message: String {
        switch self {
        case .invalidURL: return "Enter a valid http(s) URL for the version check"
        case .invalidFrequency: return "Version check frequency must be a whole number between 1 and \(VersionCheckDraft.maxEveryNChecks)"
        case .missingVersionField: return "Enter the JSON field that holds the version, e.g. data.version"
        case .incompleteAssertion: return "Each version check assertion needs both a field path and an expected value"
        case .missingHeaderName: return "Enter a header name for the version check's custom header auth"
        case .missingSecret(let type): return "Enter a value for the version check's \(type.secretFieldLabel.lowercased())"
        }
    }
}

extension AuthType {
    /// Label/placeholder for the secret field of this auth type.
    var secretFieldLabel: String {
        switch self {
        case .none: return ""
        case .bearerToken: return "Token"
        case .basicAuth: return "Password"
        case .customHeader: return "Header value"
        }
    }
}
