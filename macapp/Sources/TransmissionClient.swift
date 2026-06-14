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

    init(server: ServerConfig, timeout: TimeInterval = 15) throws {
        var components = URLComponents()
        components.scheme = server.useHTTPS ? "https" : "http"
        components.host = server.host
        components.port = server.port
        components.path = server.rpcPath
        guard let url = components.url else {
            throw TransmissionError.invalidURL
        }
        self.endpoint = url

        if let user = server.username, !user.isEmpty {
            let raw = "\(user):\(server.password ?? "")"
            let encoded = Data(raw.utf8).base64EncodedString()
            self.authHeader = "Basic \(encoded)"
        } else {
            self.authHeader = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
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

    func verify(ids: [Int]) async throws {
        try await sendIgnoringResult(method: "torrent-verify", arguments: ["ids": ids])
    }

    /// Where in the queue to move the given torrents.
    enum QueueMove: String {
        case top = "queue-move-top"
        case up = "queue-move-up"
        case down = "queue-move-down"
        case bottom = "queue-move-bottom"
    }

    func queueMove(ids: [Int], to move: QueueMove) async throws {
        try await sendIgnoringResult(method: move.rawValue, arguments: ["ids": ids])
    }

    func setBandwidthPriority(ids: [Int], priority: BandwidthPriority) async throws {
        try await sendIgnoringResult(
            method: "torrent-set",
            arguments: ["ids": ids, "bandwidthPriority": priority.rawValue]
        )
    }

    /// Fetch the file list for one torrent (`files` + `fileStats`). Kept separate
    /// from the list poll because these arrays are heavy and only needed for the
    /// selected torrent.
    func fetchFiles(id: Int) async throws -> [TorrentFile] {
        let args: [String: Any] = ["ids": [id], "fields": ["id", "files", "fileStats"]]
        let response: RPCResponse<TorrentFilesArguments> = try await send(method: "torrent-get", arguments: args)
        return response.arguments?.torrents.first?.files ?? []
    }

    func setFilesWanted(id: Int, fileIndices: [Int], wanted: Bool) async throws {
        guard !fileIndices.isEmpty else { return }
        let key = wanted ? "files-wanted" : "files-unwanted"
        try await sendIgnoringResult(method: "torrent-set", arguments: ["ids": [id], key: fileIndices])
    }

    func setFilePriority(id: Int, fileIndices: [Int], priority: FilePriority) async throws {
        guard !fileIndices.isEmpty else { return }
        let key: String
        switch priority {
        case .low: key = "priority-low"
        case .normal: key = "priority-normal"
        case .high: key = "priority-high"
        }
        try await sendIgnoringResult(method: "torrent-set", arguments: ["ids": [id], key: fileIndices])
    }

    func remove(ids: [Int], deleteLocalData: Bool) async throws {
        try await sendIgnoringResult(
            method: "torrent-remove",
            arguments: ["ids": ids, "delete-local-data": deleteLocalData]
        )
    }

    /// Add a torrent from base64 `.torrent` contents (`metainfo`) or a
    /// magnet/URL (`filename`). Returns the resulting torrent name and whether the
    /// daemon reported it as a duplicate.
    func addTorrent(metainfoBase64: String?, filename: String?,
                    downloadDir: String?, paused: Bool) async throws -> AddOutcome {
        var args: [String: Any] = ["paused": paused]
        if let metainfoBase64 { args["metainfo"] = metainfoBase64 }
        if let filename { args["filename"] = filename }
        if let downloadDir, !downloadDir.isEmpty { args["download-dir"] = downloadDir }

        let response: RPCResponse<AddArguments> = try await send(method: "torrent-add", arguments: args)
        if let dup = response.arguments?.duplicate {
            return AddOutcome(name: dup.name ?? "torrent", duplicate: true)
        }
        return AddOutcome(name: response.arguments?.added?.name ?? "torrent", duplicate: false)
    }

    /// Free space (bytes) for a server path. Returns nil if the daemon can't
    /// report it. Mirrors the legacy "Free disk space" display.
    func freeSpace(path: String) async throws -> Int64? {
        let response: RPCResponse<FreeSpaceArguments> = try await send(
            method: "free-space", arguments: ["path": path])
        return response.arguments?.sizeBytes
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
