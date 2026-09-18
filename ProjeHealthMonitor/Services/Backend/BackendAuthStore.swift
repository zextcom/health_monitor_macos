import Foundation
import Security

/// Manages the connection to the backend server: the configured server URL, the logged-in user,
/// and the access/refresh token pair persisted in the Keychain. Other services read `client` to
/// perform authenticated calls without knowing how the token lifecycle works.
@MainActor
final class BackendAuthStore: ObservableObject {
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey)
        }
    }
    @Published private(set) var currentUser: AuthUser?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    var isConnected: Bool {
        currentUser != nil
    }

    /// The active API client, available once connected. Other services should read this rather
    /// than holding their own reference, since it is replaced whenever the server URL changes.
    var client: APIClient? {
        isConnected ? apiClient : nil
    }

    private var apiClient: APIClient?

    private static let serverURLKey = "backendServerURL"
    private static let userKey = "backendUser"
    private static let keychainService = "com.zext.healthmonitor.backend"
    private static let accessTokenAccount = "accessToken"
    private static let refreshTokenAccount = "refreshToken"

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        Task { await self.restoreSession() }
    }

    // MARK: - Public API

    func connect(email: String, password: String) async {
        guard let url = URL(string: serverURL), !serverURL.isEmpty else {
            errorMessage = "Enter a valid server URL."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = APIClient(baseURL: url)
        do {
            let response = try await client.login(email: email, password: password)
            await client.setAccessToken(response.accessToken)
            self.apiClient = client
            self.currentUser = response.user
            storeTokens(accessToken: response.accessToken, refreshToken: response.refreshToken)
            storeUser(response.user)
        } catch {
            self.errorMessage = Self.message(for: error)
        }
    }

    func disconnect() {
        let refreshToken = Self.readKeychain(account: Self.refreshTokenAccount)
        if let apiClient, let refreshToken {
            Task {
                try? await apiClient.logout(refreshToken: refreshToken)
            }
        }
        Self.deleteKeychain(account: Self.accessTokenAccount)
        Self.deleteKeychain(account: Self.refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        apiClient = nil
        currentUser = nil
    }

    func restoreSession() async {
        guard !serverURL.isEmpty, let url = URL(string: serverURL) else { return }
        guard let refreshToken = Self.readKeychain(account: Self.refreshTokenAccount) else { return }
        guard let storedUser = loadStoredUser() else { return }

        let client = APIClient(baseURL: url)
        do {
            let refreshed = try await client.refresh(token: refreshToken)
            await client.setAccessToken(refreshed.accessToken)
            storeTokens(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            self.apiClient = client
            self.currentUser = storedUser
        } catch {
            // Refresh failed (expired/invalid token, unreachable server, etc.) — fail silently
            // and leave the user logged out; they can reconnect manually.
        }
    }

    // MARK: - Persistence helpers

    private func storeTokens(accessToken: String, refreshToken: String) {
        Self.writeKeychain(account: Self.accessTokenAccount, value: accessToken)
        Self.writeKeychain(account: Self.refreshTokenAccount, value: refreshToken)
    }

    private func storeUser(_ user: AuthUser) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: Self.userKey)
    }

    private func loadStoredUser() -> AuthUser? {
        guard let data = UserDefaults.standard.data(forKey: Self.userKey) else { return nil }
        return try? JSONDecoder().decode(AuthUser.self, from: data)
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIClientError {
            switch apiError {
            case .networkError:
                return "Could not reach the server."
            case .httpError(_, let message):
                return message
            case .decodingError:
                return "Received an unexpected response from the server."
            case .unauthorized:
                return "Invalid email or password."
            }
        }
        return error.localizedDescription
    }

    // MARK: - Keychain

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func writeKeychain(account: String, value: String) {
        deleteKeychain(account: account)
        guard !value.isEmpty else { return }
        var attributes = keychainQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func readKeychain(account: String) -> String? {
        var attributes = keychainQuery(account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(account: String) {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
    }
}
