import Foundation

/// `status` of a Zext Health Standard (`zext-health/v1`) response or of one of its checks. See
/// docs/health-standard.md; the backend mirrors these rules in `health-standard.ts`.
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

/// One flattened entry of a health-standard `checks` map, e.g. key `"postgres:responseTime"`.
struct HealthComponentCheck: Equatable, Identifiable {
    /// `key` plus the entry's index — a key may hold several entries (one per instance).
    let id: String
    let key: String
    let status: HealthStandardStatus
    let componentId: String?
    let componentType: String?
    /// Stringified for display (numbers via `NSNumber`, booleans as "true"/"false").
    let observedValue: String?
    let observedUnit: String?
    let time: String?
    let output: String?

    /// "12 ms", "87.2 percent", or just the value when there's no unit.
    var observedText: String? {
        guard let observedValue else { return nil }
        guard let observedUnit else { return observedValue }
        return "\(observedValue) \(observedUnit)"
    }
}

/// Lenient parse of a health-standard body: only `status` is required; malformed check entries are
/// skipped so a service is still monitored by its declared overall status (strict validation lives
/// in the backend's validate endpoint).
struct HealthStandardResponse: Equatable {
    let status: HealthStandardStatus
    let version: String?
    let releaseId: String?
    let output: String?
    let components: [HealthComponentCheck]
}

enum HealthStandard {
    static let id = "zext-health/v1"
    static let mediaType = "application/health+json"

    /// Components beyond this are dropped; long text is clipped — keeps the in-memory store small.
    static let maxComponents = 50
    static let maxTextLength = 300

    // MARK: Parsing

    static func parse(json: Any) -> Result<HealthStandardResponse, HealthStandardParseError> {
        guard let object = json as? [String: Any] else { return .failure(.notAnObject) }
        guard let rawStatus = object["status"] else { return .failure(.missingStatus) }
        guard let statusString = rawStatus as? String, let status = HealthStandardStatus(rawValue: statusString) else {
            return .failure(.invalidStatus(describe(rawStatus)))
        }

        var components: [HealthComponentCheck] = []
        if let checks = object["checks"] as? [String: Any] {
            for key in checks.keys.sorted() {
                guard let entries = checks[key] as? [Any] else { continue }
                for (index, entry) in entries.enumerated() {
                    guard components.count < maxComponents,
                          let entry = entry as? [String: Any],
                          let entryStatusString = entry["status"] as? String,
                          let entryStatus = HealthStandardStatus(rawValue: entryStatusString) else { continue }
                    components.append(HealthComponentCheck(
                        id: "\(key)#\(index)", key: clip(key), status: entryStatus,
                        componentId: text(entry["componentId"]), componentType: text(entry["componentType"]),
                        observedValue: observedValue(entry["observedValue"]), observedUnit: text(entry["observedUnit"]),
                        time: text(entry["time"]), output: text(entry["output"])))
                }
            }
        }

        return .success(HealthStandardResponse(status: status, version: text(object["version"]),
                                               releaseId: text(object["releaseId"]), output: text(object["output"]),
                                               components: components))
    }

    /// Reason for a warn/fail response: top-level `output`, else the first non-pass component as
    /// `"<key>: <status>[ — output]"`, else a generic `Health status "<status>"`. `nil` for pass.
    static func reason(for response: HealthStandardResponse) -> String? {
        guard response.status != .pass else { return nil }
        if let output = response.output { return output }
        if let problem = response.components.first(where: { $0.status != .pass }) {
            if let output = problem.output {
                return "\(problem.key): \(problem.status.rawValue) — \(output)"
            }
            return "\(problem.key): \(problem.status.rawValue)"
        }
        return "Health status \"\(response.status.rawValue)\""
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
        /// The parsed body when it could be read (components, version).
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
    /// "Status warn · version 1.4.2 (9f2c1ab) · 2 component checks · Disk usage above 85%".
    static func testSummary(_ evaluation: Evaluation) -> String {
        guard let response = evaluation.response else {
            return evaluation.failureReason ?? "Invalid health response"
        }
        var parts = ["Status \(response.status.rawValue)"]
        if let version = trackedVersion(version: response.version, releaseId: response.releaseId) {
            parts.append("version \(version)")
        }
        if !response.components.isEmpty {
            parts.append("\(response.components.count) component check\(response.components.count == 1 ? "" : "s")")
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

    private static func observedValue(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let string = value as? String { return clip(string) }
        return nil
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
