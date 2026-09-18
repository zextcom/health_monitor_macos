import Foundation

/// Periodically fetches dashboard data from the backend and exposes it for the UI. Depends on
/// `BackendAuthStore` for the active `APIClient`; when the token can no longer be refreshed it
/// disconnects the auth store rather than retrying forever.
@MainActor
final class BackendSyncService: ObservableObject {
    @Published var dashboardData: DashboardResponse?
    @Published var lastSyncError: String?
    @Published var isSyncing: Bool = false

    private let backendAuth: BackendAuthStore
    private var pollingTask: Task<Void, Never>?
    private let pollingInterval: Duration = .seconds(30)

    init(backendAuth: BackendAuthStore) {
        self.backendAuth = backendAuth
    }

    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncNow()
                do {
                    try await Task.sleep(for: self.pollingInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func syncNow() async {
        guard let client = backendAuth.client else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let dashboard = try await client.getDashboard()
            dashboardData = dashboard
            lastSyncError = nil
        } catch APIClientError.unauthorized {
            backendAuth.disconnect()
        } catch {
            lastSyncError = Self.message(for: error)
        }
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
                return "Not authorized."
            }
        }
        return error.localizedDescription
    }
}
