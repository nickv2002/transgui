import Foundation

/// One named Transmission server connection. Holds exactly the per-connection
/// fields `TransmissionClient` needs.
struct ServerConfig: Codable, Sendable, Equatable {
    var name: String
    var host: String
    var port: Int
    var useHTTPS: Bool
    var rpcPath: String
    var username: String?
    var password: String?

    enum CodingKeys: String, CodingKey {
        case name, host, port, useHTTPS, rpcPath, username, password
    }

    init(name: String, host: String, port: Int, useHTTPS: Bool, rpcPath: String,
         username: String? = nil, password: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.rpcPath = rpcPath
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9091
        // Default the display name to "host:port" if none was given.
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "\(host):\(port)"
        useHTTPS = try c.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? false
        rpcPath = try c.decodeIfPresent(String.self, forKey: .rpcPath) ?? "/transmission/rpc"
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    /// The built-in default used when the config has no servers.
    static let localhost = ServerConfig(
        name: "localhost", host: "localhost", port: 9091,
        useHTTPS: false, rpcPath: "/transmission/rpc")
}

/// User-editable app config. Loaded from a JSONC file under
/// `~/.config/transmission-remote-mac/config.jsonc`. Holds the list of named
/// servers, the active one, and the poll interval.
struct AppConfig: Codable, Sendable, Equatable {
    var servers: [ServerConfig]
    var refreshSeconds: Double
    /// Name of the server selected in the config file (the menu/UserDefaults
    /// selection takes precedence at runtime).
    var currentServer: String?

    enum CodingKeys: String, CodingKey {
        case servers, refreshSeconds, currentServer
    }

    init(servers: [ServerConfig], refreshSeconds: Double, currentServer: String? = nil) {
        self.servers = servers.isEmpty ? [.localhost] : servers
        self.refreshSeconds = max(1, refreshSeconds)
        self.currentServer = currentServer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? []
        // Fall back to a single localhost default so the app still launches when
        // `servers` is empty or missing.
        servers = decoded.isEmpty ? [.localhost] : decoded
        let refresh = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 4
        refreshSeconds = max(1, refresh)
        currentServer = try c.decodeIfPresent(String.self, forKey: .currentServer)
    }

    /// The display names of all configured servers, in file order.
    var serverNames: [String] { servers.map(\.name) }

    /// The server with the given name, if any.
    func server(named name: String) -> ServerConfig? {
        servers.first { $0.name == name }
    }
}

enum ConfigError: LocalizedError {
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Could not read the config file: \(detail)"
        case .malformed(let detail): return "The config file is not valid: \(detail)"
        }
    }
}

enum ConfigLoader {
    /// `~/.config/transmission-remote-mac/config.jsonc`
    static var configURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("transmission-remote-mac", isDirectory: true)
        return base.appendingPathComponent("config.jsonc", isDirectory: false)
    }

    /// Loads the config, creating an annotated template on first run.
    static func load() throws -> AppConfig {
        let url = configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try createTemplate(at: url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(error.localizedDescription)
        }

        // JSONDecoder has no comment support, so normalize JSONC → object via
        // JSONSerialization's JSON5 reader (handles // /* */ comments and
        // trailing commas), then re-encode and decode into the typed struct.
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            throw ConfigError.malformed(error.localizedDescription)
        }

        do {
            let normalized = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(AppConfig.self, from: normalized)
        } catch {
            throw ConfigError.malformed(error.localizedDescription)
        }
    }

    private static func createTemplate(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(error.localizedDescription)
        }
    }

    private static let template = """
    // Transmission Remote — connection config.
    // Edit this file, then choose "Reload Config" from the app menu.
    {
        // One or more Transmission servers. Pick the active one from the
        // "Server" menu in the app (the choice persists across launches).
        "servers": [
            {
                // Display name shown in the Server menu.
                "name": "Local",

                // Hostname or IP of the machine running the Transmission daemon.
                "host": "localhost",

                // RPC port (Transmission default is 9091).
                "port": 9091,

                // Use HTTPS instead of plain HTTP.
                "useHTTPS": false,

                // RPC path. Leave as-is unless your server uses a custom path.
                "rpcPath": "/transmission/rpc",

                // Credentials. Leave username empty if the daemon has no auth.
                // NOTE: stored in plaintext for now; a future version will use the Keychain.
                "username": "",
                "password": ""
            },
            {
                "name": "Remote",
                "host": "192.168.1.10",
                "port": 9091,
                "useHTTPS": false,
                "rpcPath": "/transmission/rpc",
                "username": "",
                "password": ""
            }
        ],

        // Which server to connect to by name on first launch.
        "currentServer": "Local",

        // How often to poll the server for torrent updates, in seconds.
        "refreshSeconds": 4
    }
    """
}
