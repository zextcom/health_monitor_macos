import Foundation

/// Errors surfaced by `APIClient` network calls.
enum APIClientError: Error, Sendable {
    case networkError(Error)
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case unauthorized
}

/// Actor-based HTTP client for the Fastify backend API, reachable at `{baseURL}/api/...`.
/// Not `@MainActor` — this is a network actor whose methods are safe to call from any isolation
/// context; callers `await` the result on whichever actor they run on.
actor APIClient {
    private(set) var baseURL: URL
    private(set) var accessToken: String?

    private let decoder: JSONDecoder = JSONDecoder()
    private let encoder: JSONEncoder = JSONEncoder()

    init(baseURL: URL, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    func setAccessToken(_ token: String?) {
        self.accessToken = token
    }

    func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    // MARK: - Auth

    private struct LoginBody: Encodable, Sendable {
        let email: String
        let password: String
    }

    private struct RegisterBody: Encodable, Sendable {
        let email: String
        let password: String
        let name: String
    }

    private struct RefreshBody: Encodable, Sendable {
        let refreshToken: String
    }

    private struct LogoutBody: Encodable, Sendable {
        let refreshToken: String
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        try await request(
            "POST",
            path: "/api/auth/login",
            body: LoginBody(email: email, password: password)
        )
    }

    func register(email: String, password: String, name: String) async throws -> AuthUser {
        try await request(
            "POST",
            path: "/api/auth/register",
            body: RegisterBody(email: email, password: password, name: name)
        )
    }

    func refresh(token: String) async throws -> RefreshResponse {
        try await request(
            "POST",
            path: "/api/auth/refresh",
            body: RefreshBody(refreshToken: token)
        )
    }

    func logout(refreshToken: String) async throws {
        try await requestNoContent(
            "POST",
            path: "/api/auth/logout",
            body: LogoutBody(refreshToken: refreshToken)
        )
    }

    // MARK: - Dashboard

    func getDashboard() async throws -> DashboardResponse {
        try await request("GET", path: "/api/dashboard")
    }

    // MARK: - Endpoints

    func getEndpoints() async throws -> [BackendEndpoint] {
        try await request("GET", path: "/api/endpoints")
    }

    // MARK: - Core request helpers

    private func makeRequest(method: String, path: String, body: (any Encodable)?) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw APIClientError.networkError(error)
            }
        }
        return request
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    /// Sends the request and validates the HTTP status, returning the raw response data on success.
    private func send(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw APIClientError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return data
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw APIClientError.unauthorized
            }
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw APIClientError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws -> T {
        let urlRequest = try makeRequest(method: method, path: path, body: body)
        let data = try await send(urlRequest)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIClientError.decodingError(error)
        }
    }

    private func requestNoContent(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws {
        let urlRequest = try makeRequest(method: method, path: path, body: body)
        _ = try await send(urlRequest)
    }
}
