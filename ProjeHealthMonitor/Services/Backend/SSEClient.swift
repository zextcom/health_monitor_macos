import Foundation

// MARK: - SSE Event Types

/// Events emitted by the SSE client to its consumer.
enum SSEEvent: Sendable {
    /// The server acknowledged the connection with a `{"type":"connected"}` message.
    case connected
    /// A health-check result arrived for one endpoint.
    case checkResult(SSECheckResult)
    /// The stream disconnected (network error, server close, etc.). The client will attempt
    /// to reconnect automatically; the consumer can use this to adjust its polling rate.
    case disconnected
}

/// A health-check result received via SSE from the backend.
struct SSECheckResult: Decodable, Sendable {
    let endpointId: String
    let isHealthy: Bool
    let responseTimeMs: Int?
    let statusCode: Int?
    let failureReason: String?
    let timestamp: String
}

// MARK: - SSE Client

/// Lightweight Server-Sent Events client that connects to the backend's `/api/sse/checks`
/// endpoint and delivers parsed events to a `@MainActor` callback. Handles automatic
/// reconnection with exponential backoff on disconnect or error.
///
/// Usage:
/// ```
/// let sse = SSEClient(baseURL: url, accessToken: token) { event in
///     // runs on MainActor
/// }
/// await sse.connect()
/// // later…
/// await sse.disconnect()
/// ```
actor SSEClient {
    private let baseURL: URL
    private let accessToken: String
    private let onEvent: @MainActor @Sendable (SSEEvent) -> Void

    // nonisolated(unsafe) so `deinit` can cancel it without actor isolation.
    nonisolated(unsafe) private var connectionTask: Task<Void, Never>?

    init(
        baseURL: URL,
        accessToken: String,
        onEvent: @escaping @MainActor @Sendable (SSEEvent) -> Void
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.onEvent = onEvent
    }

    deinit {
        connectionTask?.cancel()
    }

    /// Start the SSE connection. Reconnects automatically with exponential backoff when the
    /// stream drops. Safe to call multiple times — previous connections are cancelled first.
    func connect() {
        disconnect()

        let baseURL = self.baseURL
        let accessToken = self.accessToken
        let onEvent = self.onEvent

        connectionTask = Task {
            var backoff: UInt64 = 1 // seconds
            let maxBackoff: UInt64 = 30

            while !Task.isCancelled {
                let didReceiveEvents = await Self.connectAndStream(
                    baseURL: baseURL,
                    accessToken: accessToken,
                    onEvent: onEvent
                )

                if Task.isCancelled { return }
                await onEvent(.disconnected)

                // Reset backoff when the connection was healthy (received at least one event).
                if didReceiveEvents {
                    backoff = 1
                }

                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, maxBackoff)
            }
        }
    }

    /// Stop the SSE connection and cancel any pending reconnection attempt.
    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
    }

    // MARK: - Streaming

    /// Opens the SSE stream, reads lines, and dispatches parsed events via the callback.
    /// Returns `true` if at least one event was successfully received (used to reset backoff).
    private static func connectAndStream(
        baseURL: URL,
        accessToken: String,
        onEvent: @MainActor @Sendable (SSEEvent) -> Void
    ) async -> Bool {
        do {
            let url = baseURL.appendingPathComponent("api/sse/checks")
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // Generous timeout — the server sends heartbeat comments every 30s, so 120s
            // ensures the connection survives a few missed heartbeats without dropping.
            request.timeoutInterval = 120

            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return false
            }

            var dataBuffer = ""
            var didReceiveEvent = false

            for try await line in bytes.lines {
                if Task.isCancelled { return didReceiveEvent }

                // SSE comment lines (heartbeats, etc.) — skip silently.
                if line.hasPrefix(":") {
                    continue
                }

                // An empty line marks the end of an SSE event — dispatch the accumulated data.
                if line.isEmpty {
                    if !dataBuffer.isEmpty {
                        await dispatchEvent(data: dataBuffer, onEvent: onEvent)
                        didReceiveEvent = true
                        dataBuffer = ""
                    }
                    continue
                }

                // Accumulate data lines. Per the SSE spec, strip the "data:" prefix and an
                // optional single leading space. Multiple data lines are joined with newlines.
                if line.hasPrefix("data:") {
                    let payload = String(line.dropFirst(5))
                    let trimmed = payload.hasPrefix(" ") ? String(payload.dropFirst()) : payload
                    dataBuffer = dataBuffer.isEmpty ? trimmed : dataBuffer + "\n" + trimmed
                }
                // event:, id:, retry: fields are silently ignored.
            }

            return didReceiveEvent
        } catch {
            return false
        }
    }

    /// Parses an SSE data payload as JSON and dispatches the appropriate event.
    private static func dispatchEvent(
        data: String,
        onEvent: @MainActor @Sendable (SSEEvent) -> Void
    ) async {
        guard let jsonData = data.data(using: .utf8) else { return }

        // Try the "connected" handshake message first.
        struct ConnectedMessage: Decodable {
            let type: String
        }
        if let msg = try? JSONDecoder().decode(ConnectedMessage.self, from: jsonData),
           msg.type == "connected" {
            await onEvent(.connected)
            return
        }

        // Try a health-check result.
        if let result = try? JSONDecoder().decode(SSECheckResult.self, from: jsonData) {
            await onEvent(.checkResult(result))
        }
    }
}
