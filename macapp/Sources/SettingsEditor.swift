import Foundation

/// The editing model behind the Settings window: a working copy of `AppConfig`,
/// the last-saved baseline (for dirty detection / revert), and all the mutations
/// the UI performs (add / remove / edit servers, default server, refresh). Pure
/// (Foundation-only) so the add/remove/change/save behaviors are unit-tested
/// without any AppKit.
struct SettingsEditor: Equatable {
    /// The in-progress edits.
    private(set) var working: AppConfig
    /// The last saved state (what `working` is compared against / reverts to).
    private(set) var savedBaseline: AppConfig

    init(_ config: AppConfig) {
        // Normalize once so a freshly opened editor isn't spuriously "dirty".
        let normalized = AppConfig(servers: config.servers,
                                   refreshSeconds: config.refreshSeconds,
                                   currentServer: config.currentServer)
        self.working = normalized
        self.savedBaseline = normalized
    }

    // MARK: - Reads

    var servers: [ServerConfig] { working.servers }
    var serverCount: Int { working.servers.count }
    var serverNames: [String] { working.serverNames }
    var currentServer: String? { working.currentServer }
    var refreshSeconds: Double { working.refreshSeconds }

    func server(at index: Int) -> ServerConfig? {
        working.servers.indices.contains(index) ? working.servers[index] : nil
    }

    /// The working copy normalized through `AppConfig.init` (clamps + fallbacks).
    func normalized() -> AppConfig {
        AppConfig(servers: working.servers,
                  refreshSeconds: working.refreshSeconds,
                  currentServer: working.currentServer)
    }

    /// True when there are changes not yet saved.
    var isDirty: Bool { normalized() != savedBaseline }

    // MARK: - Mutations

    /// Append a new server with a unique "New Server" name; returns its index.
    @discardableResult
    mutating func addServer() -> Int {
        let base = "New Server"
        var name = base
        var n = 2
        while working.servers.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"; n += 1
        }
        working.servers.append(ServerConfig(
            name: name, host: "", port: 9091,
            useHTTPS: false, rpcPath: "/transmission/rpc"))
        return working.servers.count - 1
    }

    /// Remove the server at `index`. No-op if it would empty the list or the
    /// index is invalid. If the removed server was the default, the default falls
    /// back to the first remaining server.
    mutating func removeServer(at index: Int) {
        guard working.servers.count > 1, working.servers.indices.contains(index) else { return }
        let removed = working.servers.remove(at: index)
        if working.currentServer == removed.name {
            working.currentServer = working.servers.first?.name
        }
    }

    /// Replace the server at `index` with `candidate`. When `normalizeName` is
    /// true (end-of-edit), the name is trimmed, kept non-empty, and kept unique —
    /// otherwise it's taken as-is (live per-keystroke). If the name changes and it
    /// was the default server, the default follows the rename. Returns the server
    /// actually stored (its `name` may differ from `candidate` after normalizing).
    @discardableResult
    mutating func updateServer(at index: Int, to candidate: ServerConfig,
                               normalizeName: Bool) -> ServerConfig {
        guard working.servers.indices.contains(index) else { return candidate }
        var s = candidate
        let oldName = working.servers[index].name
        if normalizeName {
            let trimmed = s.name.trimmingCharacters(in: .whitespaces)
            s.name = trimmed.isEmpty ? oldName : trimmed
            // Keep names unique (compare against the other rows).
            let clashesElsewhere = working.servers.enumerated().contains { i, other in
                i != index && other.name == s.name
            }
            if s.name != oldName && clashesElsewhere { s.name = oldName }
        }
        if s.name != oldName, working.currentServer == oldName {
            working.currentServer = s.name
        }
        working.servers[index] = s
        return s
    }

    mutating func setDefaultServer(_ name: String?) {
        working.currentServer = name
    }

    mutating func setRefreshSeconds(_ seconds: Double) {
        working.refreshSeconds = seconds
    }

    // MARK: - Save / reset

    /// Commit the working copy: the normalized config becomes the new baseline and
    /// working copy, and is returned for persistence.
    @discardableResult
    mutating func save() -> AppConfig {
        let normalized = normalized()
        savedBaseline = normalized
        working = normalized
        return normalized
    }

    /// Re-seed both working copy and baseline (e.g. when the window is reopened).
    mutating func reset(to config: AppConfig) {
        self = SettingsEditor(config)
    }
}
