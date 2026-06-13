import Foundation

/// User-editable connection config. Loaded from a JSONC file under
/// `~/.config/transmission-remote-mac/config.jsonc`.
struct AppConfig: Codable, Sendable, Equatable {
    var host: String
    var port: Int
    var useHTTPS: Bool
    var rpcPath: String
    var username: String?
    var password: String?
    var refreshSeconds: Double

    enum CodingKeys: String, CodingKey {
        case host, port, useHTTPS, rpcPath, username, password, refreshSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9091
        useHTTPS = try c.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? false
        rpcPath = try c.decodeIfPresent(String.self, forKey: .rpcPath) ?? "/transmission/rpc"
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        let refresh = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 4
        refreshSeconds = max(1, refresh)
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
        "password": "",

        // How often to poll the server for torrent updates, in seconds.
        "refreshSeconds": 4
    }
    """
}
