import Foundation

/// Periodically fetches dashboard data from the backend and exposes it for the UI. Depends on
/// `BackendAuthStore` for the active `APIClient`; when the token can no longer be refreshed it
/// disconnects the auth store rather than retrying forever.
///
/// When connected, also maintains an SSE stream for real-time health-check updates. The polling
/// interval increases to 120 seconds while SSE is active, falling back to 30 seconds when the
/// SSE stream is disconnected.
@MainActor
final class BackendSyncService: ObservableObject {
    @Published var dashboardData: DashboardResponse?
    @Published var lastSyncError: String?
    @Published var isSyncing: Bool = false

    private let backendAuth: BackendAuthStore
    /// Set after initialisation so widget data can be refreshed when the backend pushes new
    /// dashboard state.
    weak var endpointStore: EndpointStore?
    private var pollingTask: Task<Void, Never>?
    private var sseClient: SSEClient?
    private var sseConnected: Bool = false
    private var pendingSyncTask: Task<Void, Never>?

    /// Polling interval adapts to SSE connection status: 120s when SSE is live, 30s otherwise.
    private var effectivePollingInterval: Duration {
        sseConnected ? .seconds(120) : .seconds(30)
    }

    init(backendAuth: BackendAuthStore) {
        self.backendAuth = backendAuth
    }

    func startPolling() {
        stopPolling()
        pollingTask = makePollingLoop()
        startSSE()
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        stopSSE()
    }

    func syncNow() async {
        guard let client = backendAuth.client else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let dashboard = try await client.getDashboard()
            dashboardData = dashboard
            lastSyncError = nil
            endpointStore?.updateWidgetData()
        } catch APIClientError.unauthorized {
            backendAuth.disconnect()
        } catch {
            lastSyncError = Self.message(for: error)
        }
    }

    // MARK: - SSE

    private func startSSE() {
        guard let client = backendAuth.client else { return }

        Task {
            let baseURL = await client.baseURL
            guard let accessToken = await client.accessToken else { return }

            // Bail out if polling was stopped while we were awaiting the token.
            guard self.pollingTask != nil else { return }

            let sse = SSEClient(
                baseURL: baseURL,
                accessToken: accessToken,
                onEvent: { [weak self] event in
                    self?.handleSSEEvent(event)
                }
            )
            self.sseClient = sse
            await sse.connect()
        }
    }

    private func stopSSE() {
        if let sseClient {
            Task { await sseClient.disconnect() }
        }
        sseClient = nil
        sseConnected = false
    }

    private func handleSSEEvent(_ event: SSEEvent) {
        switch event {
        case .connected:
            sseConnected = true

        case .disconnected:
            sseConnected = false
            // Restart the polling loop so it immediately switches to the faster 30s interval
            // instead of waiting out a potentially long 120s sleep.
            if pollingTask != nil {
                pollingTask?.cancel()
                pollingTask = makePollingLoop()
            }

        case .checkResult:
            scheduleSync()
        }
    }

    /// Debounced sync: waits 1 second, then fetches the full dashboard. If multiple SSE events
    /// arrive in quick succession (e.g. a batch of checks), a single dashboard refresh covers
    /// them all.
    private func scheduleSync() {
        guard pendingSyncTask == nil else { return }
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
            self?.pendingSyncTask = nil
        }
    }

    // MARK: - Polling loop

    private func makePollingLoop() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncNow()
                do {
                    try await Task.sleep(for: self.effectivePollingInterval)
                } catch {
                    return
                }
            }
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
