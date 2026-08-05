import Foundation
import Security

/// Stores secrets (endpoint auth tokens/passwords, the GitHub PAT used for update checks while
/// the repo is private) in the macOS Keychain, keyed by an arbitrary account string. `Endpoint`
/// itself is plain JSON in `UserDefaults` (see `EndpointStore`), so secrets must never be attached
/// to it — this is the only place they live. Stateless by design (Keychain is already a global,
/// thread-safe OS service), so static functions are used rather than an injected instance —
/// consistent with how `HealthCheckService.executeCheck` already takes a plain `secret: String?`
/// parameter instead of depending on this type directly.
enum SecretStore {
    private static let service = "com.oneoapps.projehealthmonitor.endpointAuth"

    /// Account key for the GitHub Personal Access Token used to authenticate Sparkle's update
    /// checks while the repo is private (see `UpdaterViewModel`).
    static let updateTokenAccount = "github-update-token"

    static func setSecret(_ value: String, for account: String) {
        deleteSecret(for: account)
        guard !value.isEmpty else { return }
        var attributes = query(for: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func secret(for account: String) -> String? {
        var attributes = query(for: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(for account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
    }

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
