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
    /// Remote→local path-mapping rules (see `PathMapping`). Empty for servers that
    /// never need them; populated via the Settings screen.
    var pathMappings: [PathMapping]

    enum CodingKeys: String, CodingKey {
        case name, host, port, useHTTPS, rpcPath, username, password, pathMappings
    }

    init(name: String, host: String, port: Int, useHTTPS: Bool, rpcPath: String,
         username: String? = nil, password: String? = nil,
         pathMappings: [PathMapping] = []) {
        self.name = name
        self.host = host
        self.port = port
        self.useHTTPS = useHTTPS
        self.rpcPath = rpcPath
        self.username = username
        self.password = password
        self.pathMappings = pathMappings
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
        // Backward-compatible: configs written before this feature have no key.
        pathMappings = try c.decodeIfPresent([PathMapping].self, forKey: .pathMappings) ?? []
    }

    /// The built-in default used when the config has no servers.
    static let localhost = ServerConfig(
        name: "localhost", host: "localhost", port: 9091,
        useHTTPS: false, rpcPath: "/transmission/rpc")
}

/// App configuration: the list of named servers, the active one, and the poll
/// interval. Persisted natively as JSON under Application Support by
/// `PreferencesStore` (migrated from the legacy JSONC file on first run) and
/// edited through the native Settings window.
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

    /// The built-in default config used when nothing is stored yet.
    static let `default` = AppConfig(servers: [.localhost], refreshSeconds: 4,
                                     currentServer: ServerConfig.localhost.name)

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
        case .unreadable(let detail): return "Could not read the preferences file: \(detail)"
        case .malformed(let detail): return "The preferences file is not valid: \(detail)"
        }
    }
}

/// Native preferences store. Persists `AppConfig` as JSON under
/// `~/Library/Application Support/Transmission Remote/preferences.json` (a
/// standard macOS location), replacing the old hand-edited JSONC file. On first
/// run it migrates any legacy JSONC config so an existing server list (including
/// credentials) carries over automatically.
enum PreferencesStore {
    /// The Application Support folder for this app.
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Transmission Remote", isDirectory: true)
    }

    /// `~/Library/Application Support/Transmission Remote/preferences.json`
    static var storeURL: URL {
        supportDirectory.appendingPathComponent("preferences.json", isDirectory: false)
    }

    /// The legacy JSONC file we migrate from (and then leave in place as a backup).
    static var legacyConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("transmission-remote-mac", isDirectory: true)
            .appendingPathComponent("config.jsonc", isDirectory: false)
    }

    /// Load the stored preferences, migrating from legacy JSONC or seeding a
    /// default on first run. Always leaves a `preferences.json` on disk afterward.
    static func load() throws -> AppConfig {
        try load(storeURL: storeURL, legacyURL: legacyConfigURL)
    }

    /// Persist the config as pretty-printed JSON, creating the support folder.
    static func save(_ config: AppConfig) throws {
        try save(config, to: storeURL)
    }

    // MARK: - Testable core (path-injectable)

    /// Load from `storeURL`, migrating from `legacyURL` (or the built-in default)
    /// when no native store exists yet, then persisting the result.
    static func load(storeURL: URL, legacyURL: URL?) throws -> AppConfig {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: storeURL)
            } catch {
                throw ConfigError.unreadable(error.localizedDescription)
            }
            return try decode(data)
        }

        // First run for the native store: migrate the legacy JSONC if present,
        // otherwise start from the built-in default.
        let migrated = (legacyURL.flatMap { try? loadLegacyJSONC(from: $0) }) ?? .default
        try save(migrated, to: storeURL)
        return migrated
    }

    static func save(_ config: AppConfig, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(config).write(to: url, options: .atomic)
        } catch {
            throw ConfigError.unreadable(error.localizedDescription)
        }
    }

    /// Decode native preferences JSON into an `AppConfig`.
    static func decode(_ data: Data) throws -> AppConfig {
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigError.malformed(error.localizedDescription)
        }
    }

    /// Encode an `AppConfig` to pretty-printed, key-sorted JSON.
    static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Read a legacy JSONC config from `url`, or nil if the file is absent.
    static func loadLegacyJSONC(from url: URL) throws -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // JSONDecoder has no comment support, so normalize JSONC → object via
        // JSONSerialization's JSON5 reader (handles // /* */ comments and
        // trailing commas), then re-encode and decode into the typed struct.
        let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        let normalized = try JSONSerialization.data(withJSONObject: object)
        return try decode(normalized)
    }
}
