import Foundation
import Security

/// Stores per-endpoint auth secrets (bearer token, basic-auth password, custom header value) in
/// the macOS Keychain, keyed by endpoint UUID. `Endpoint` itself is plain JSON in `UserDefaults`
/// (see `EndpointStore`), so secrets must never be attached to it — this is the only place they live.
/// Stateless by design (Keychain is already a global, thread-safe OS service), so static functions
/// are used rather than an injected instance — consistent with how `HealthCheckService.executeCheck`
/// already takes a plain `secret: String?` parameter instead of depending on this type directly.
enum SecretStore {
    private static let service = "com.oneoapps.projehealthmonitor.endpointAuth"

    static func setSecret(_ value: String, for endpointId: UUID) {
        deleteSecret(for: endpointId)
        guard !value.isEmpty else { return }
        var attributes = query(for: endpointId)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func secret(for endpointId: UUID) -> String? {
        var attributes = query(for: endpointId)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(for endpointId: UUID) {
        SecItemDelete(query(for: endpointId) as CFDictionary)
    }

    private static func query(for endpointId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointId.uuidString,
        ]
    }
}
