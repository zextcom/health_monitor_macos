import Foundation

/// `status` of a Zext Health Standard (`zext-health/v1`) response. See docs/health-standard.md; the
/// backend mirrors these rules in `health-standard.ts`.
enum HealthStandardStatus: String, Codable, CaseIterable, Comparable {
    case pass, warn, fail

    private var severity: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .fail: return 2
        }
    }

    static func < (lhs: HealthStandardStatus, rhs: HealthStandardStatus) -> Bool {
        lhs.severity < rhs.severity
    }

    /// fail > warn > pass; `.pass` for an empty list.
    static func worst<S: Sequence>(_ statuses: S) -> HealthStandardStatus where S.Element == HealthStandardStatus {
        statuses.max() ?? .pass
    }
}

/// Lenient parse of a health-standard body: only `status` is required. Unknown fields (including a
/// legacy `checks` block, which the standard no longer defines) are ignored, so a service is monitored
/// by its declared overall status (strict validation lives in the backend's validate endpoint).
struct HealthStandardResponse: Equatable {
    let status: HealthStandardStatus
    let version: String?
    let releaseId: String?
    let output: String?
}

enum HealthStandard {
    static let id = "zext-health/v1"
    static let mediaType = "application/health+json"

    /// Long text is clipped — keeps the in-memory store small.
    static let maxTextLength = 300

    // MARK: Parsing

    static func parse(json: Any) -> Result<HealthStandardResponse, HealthStandardParseError> {
        guard let object = json as? [String: Any] else { return .failure(.notAnObject) }
        guard let rawStatus = object["status"] else { return .failure(.missingStatus) }
        guard let statusString = rawStatus as? String, let status = HealthStandardStatus(rawValue: statusString) else {
            return .failure(.invalidStatus(describe(rawStatus)))
        }

        return .success(HealthStandardResponse(status: status, version: text(object["version"]),
                                               releaseId: text(object["releaseId"]), output: text(object["output"])))
    }

    /// Reason for a warn/fail response: top-level `output`, else a generic `Health status "<status>"`.
    /// `nil` for pass.
    static func reason(for response: HealthStandardResponse) -> String? {
        guard response.status != .pass else { return nil }
        return response.output ?? "Health status \"\(response.status.rawValue)\""
    }

    /// Value fed into version tracking when there's no explicit version check:
    /// `"<version> (<releaseId first 7>)"`, else whichever exists, else `nil`.
    static func trackedVersion(version: String?, releaseId: String?) -> String? {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let releaseId = releaseId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let version, let releaseId {
            return "\(version) (\(releaseId.prefix(7)))"
        }
        return version ?? releaseId
    }

    // MARK: Evaluation

    struct Evaluation: Equatable {
        let isHealthy: Bool
        /// Up, but the service reported `warn`.
        let isDegraded: Bool
        /// Down reason, or the warn reason for a degraded result.
        let failureReason: String?
        /// The parsed body when it could be read (status, version).
        let response: HealthStandardResponse?
    }

    /// Same rules as the backend's `evaluateStandardHttpCheck`:
    /// - only HTTP 200 and 503 are readable (`expectedStatusCode` is ignored), anything else is down;
    /// - the body must parse and carry a valid `status`, else "Invalid health response: …";
    /// - 503 with a pass/warn body is contradictory and treated as invalid;
    /// - pass → healthy, warn → healthy but degraded, fail → down;
    /// - `assertions` are ANDed on top of a pass/warn body.
    static func evaluate(statusCode: Int, data: Data, assertions: [JSONAssertion] = []) -> Evaluation {
        func down(_ reason: String, _ response: HealthStandardResponse? = nil) -> Evaluation {
            Evaluation(isHealthy: false, isDegraded: false, failureReason: reason, response: response)
        }

        guard statusCode == 200 || statusCode == 503 else { return down("Unexpected HTTP \(statusCode)") }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return down("Invalid health response: body is not valid JSON")
        }
        let response: HealthStandardResponse
        switch parse(json: json) {
        case .failure(let error): return down("Invalid health response: \(error.message)")
        case .success(let parsed): response = parsed
        }
        if statusCode == 503, response.status != .fail {
            return down("Invalid health response: HTTP 503 with status \"\(response.status.rawValue)\"")
        }
        if response.status == .fail {
            return down(reason(for: response) ?? "Health status \"fail\"", response)
        }
        if !assertions.isEmpty {
            let (passed, assertionReason) = HealthCheckService.evaluateAssertions(json: json, assertions: assertions)
            if !passed {
                return down(assertionReason ?? "Assertion failed", response)
            }
        }
        return Evaluation(isHealthy: true, isDegraded: response.status == .warn, failureReason: reason(for: response),
                          response: response)
    }

    // MARK: Detection (endpoint form)

    /// Whether a "Test Connection" response looks like it follows the standard: the dedicated media
    /// type, or a JSON object with a top-level `status` of pass/warn/fail.
    static func looksStandard(contentType: String?, json: Any?) -> Bool {
        if let contentType, contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == mediaType {
            return true
        }
        guard let object = json as? [String: Any], let status = object["status"] as? String else { return false }
        return HealthStandardStatus(rawValue: status) != nil
    }

    /// One-line summary of a "Test Connection" response evaluated as a health-standard endpoint, e.g.
    /// "Status warn · version 1.4.2 (9f2c1ab) · Cache unavailable".
    static func testSummary(_ evaluation: Evaluation) -> String {
        guard let response = evaluation.response else {
            return evaluation.failureReason ?? "Invalid health response"
        }
        var parts = ["Status \(response.status.rawValue)"]
        if let version = trackedVersion(version: response.version, releaseId: response.releaseId) {
            parts.append("version \(version)")
        }
        if let reason = evaluation.failureReason {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private static func clip(_ value: String) -> String {
        value.count > maxTextLength ? String(value.prefix(maxTextLength - 1)) + "…" : value
    }

    /// Trimmed non-empty string; numbers are accepted leniently (e.g. a numeric build id).
    private static func text(_ value: Any?) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return clip(string)
    }

    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return "\(type(of: value))"
    }
}

enum HealthStandardParseError: Error, Equatable {
    case notAnObject
    case missingStatus
    case invalidStatus(String)

    var message: String {
        switch self {
        case .notAnObject: return "body is not a JSON object"
        case .missingStatus: return "missing \"status\""
        case .invalidStatus(let value): return "invalid status \(value)"
        }
    }
}

/// Health of one endpoint at one point in time — degraded counts as up for uptime/incidents but is
/// surfaced separately in the UI and notifications.
enum EndpointHealthState: Equatable {
    case healthy, degraded, down

    init(_ result: HealthCheckResult) {
        if !result.isHealthy {
            self = .down
        } else {
            self = result.isDegraded ? .degraded : .healthy
        }
    }
}

/// Notification-worthy health transitions (see `HealthCheckService.healthTransition`).
enum HealthTransition: Equatable {
    case down(reason: String?)
    /// From down. `degradedReason` is set when the endpoint came back degraded — down → degraded
    /// sends only this one notification, worded as degraded.
    case recovered(degradedReason: String?)
    case degraded(reason: String?)
    case noLongerDegraded
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
