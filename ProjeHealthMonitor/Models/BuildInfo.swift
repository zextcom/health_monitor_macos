import Foundation

/// Version details for the About screen. The commit is stamped into `Info.plist` at build time
/// (`GitCommit`, see the "Stamp git commit" script in `project.yml`), so a running build can be
/// traced back to the exact commit it was built from.
enum BuildInfo {
    /// The stamped short commit hash, or `nil` when it's missing or not a plausible hash (the
    /// build couldn't reach git, or it's an unstamped dev run).
    static func commit(in bundle: Bundle = .main) -> String? {
        normalizedCommit(bundle.infoDictionary?["GitCommit"] as? String)
    }

    static func normalizedCommit(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard (7...40).contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }

    /// "Version 0.2.0 (30) · 8f3c2a1" — the commit part is omitted when unknown.
    static func versionLine(shortVersion: String, build: String, commit: String?) -> String {
        let base = "Version \(shortVersion) (\(build))"
        guard let commit else { return base }
        return "\(base) · \(commit)"
    }
}
