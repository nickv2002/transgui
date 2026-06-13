import Foundation

/// Errors surfaced by `TransmissionClient`.
enum TransmissionError: LocalizedError {
    case invalidURL
    case authenticationFailed
    case connectionFailed(String)
    case httpError(Int)
    case rpcError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL in the config is invalid."
        case .authenticationFailed:
            return "Authentication failed — check the username and password."
        case .connectionFailed(let detail):
            return "Connection failed — \(detail)"
        case .httpError(let code):
            return "The server returned HTTP \(code)."
        case .rpcError(let message):
            return "The server reported an error: \(message)"
        case .decodingFailed(let detail):
            return "Could not read the server response: \(detail)"
        }
    }
}

/// Talks to a single Transmission daemon over JSON-RPC. Handles HTTP Basic auth
/// and the CSRF `X-Transmission-Session-Id` 409 dance (see `rpc.pas`).
actor TransmissionClient {
    private let endpoint: URL
    private let authHeader: String?
    private let session: URLSession
    private var sessionId: String?

    private static let sessionIdHeader = "X-Transmission-Session-Id"

    init(config: AppConfig) throws {
        var components = URLComponents()
        components.scheme = config.useHTTPS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = config.rpcPath
        guard let url = components.url else {
            throw TransmissionError.invalidURL
        }
        self.endpoint = url

        if let user = config.username, !user.isEmpty {
            let raw = "\(user):\(config.password ?? "")"
            let encoded = Data(raw.utf8).base64EncodedString()
            self.authHeader = "Basic \(encoded)"
        } else {
            self.authHeader = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Typed wrappers

    func fetchSession() async throws -> SessionInfo {
        let response: RPCResponse<SessionInfo> = try await send(method: "session-get", arguments: [:])
        guard let info = response.arguments else {
            throw TransmissionError.decodingFailed("missing session arguments")
        }
        return info
    }

    func fetchTorrents() async throws -> [Torrent] {
        let args: [String: Any] = ["fields": Torrent.requestedFields]
        let response: RPCResponse<TorrentListArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents ?? []
    }

    func start(ids: [Int]) async throws {
        try await sendIgnoringResult(method: "torrent-start", arguments: ["ids": ids])
    }

    func stop(ids: [Int]) async throws {
        try await sendIgnoringResult(method: "torrent-stop", arguments: ["ids": ids])
    }

    func startNow(ids: [Int]) async throws {
        try await sendIgnoringResult(method: "torrent-start-now", arguments: ["ids": ids])
    }

    func rename(id: Int, path: String, name: String) async throws {
        try await sendIgnoringResult(
            method: "torrent-rename-path",
            arguments: ["ids": [id], "path": path, "name": name]
        )
    }

    func setLocation(ids: [Int], location: String, move: Bool) async throws {
        try await sendIgnoringResult(
            method: "torrent-set-location",
            arguments: ["ids": ids, "location": location, "move": move]
        )
    }

    // MARK: - Core

    /// A response whose `arguments` we don't need to inspect.
    private struct EmptyArguments: Decodable, Sendable {}

    private func sendIgnoringResult(method: String, arguments: [String: Any]) async throws {
        let _: RPCResponse<EmptyArguments> = try await send(method: method, arguments: arguments)
    }

    /// POSTs `{ method, arguments }`. On HTTP 409 captures the session id and
    /// retries once. Decodes the typed envelope and verifies `result == "success"`.
    private func send<Arguments: Decodable>(
        method: String,
        arguments: [String: Any]
    ) async throws -> RPCResponse<Arguments> {
        let body = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "arguments": arguments,
        ])

        let (data, http) = try await perform(body: body, allowRetry: true)

        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401: throw TransmissionError.authenticationFailed
            default: throw TransmissionError.httpError(http.statusCode)
            }
        }

        let decoded: RPCResponse<Arguments>
        do {
            decoded = try JSONDecoder().decode(RPCResponse<Arguments>.self, from: data)
        } catch {
            throw TransmissionError.decodingFailed(error.localizedDescription)
        }

        guard decoded.result == "success" else {
            throw TransmissionError.rpcError(decoded.result)
        }
        return decoded
    }

    private func perform(body: Data, allowRetry: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: Self.sessionIdHeader)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TransmissionError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransmissionError.connectionFailed("non-HTTP response")
        }

        // CSRF: capture the session id from the 409 and replay once.
        if http.statusCode == 409, allowRetry,
           let newId = http.value(forHTTPHeaderField: Self.sessionIdHeader) {
            sessionId = newId
            return try await perform(body: body, allowRetry: false)
        }

        return (data, http)
    }
}
