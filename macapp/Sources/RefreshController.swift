import AppKit

/// Owns the `TransmissionClient` and polls `torrent-get` on an interval, publishing
/// results to its delegate on the main actor. Pauses while the window is hidden.
@MainActor
final class RefreshController {
    enum State: Equatable {
        case idle
        case connecting
        case connected(version: String)
        case failed(String)
    }

    /// Called on every successful refresh with the latest torrent list.
    var onTorrents: (([Torrent]) -> Void)?
    /// Called whenever the connection state changes (connecting/connected/failed).
    var onState: ((State) -> Void)?
    /// Called when a poll starts/finishes (true = a fetch is in flight). Fires only
    /// on transitions so rapid polls don't thrash the UI.
    var onFetchingChanged: ((Bool) -> Void)?

    private var config: AppConfig
    private var client: TransmissionClient?

    /// The active server's name, resolved from UserDefaults → config → first server.
    private var selectedServerName: String

    /// UserDefaults key persisting the user's server selection across launches.
    private static let selectedServerKey = "SelectedServerName"

    /// Whether a poll is currently in flight (drives the bottom-left spinner).
    private var isFetching = false {
        didSet { if oldValue != isFetching { onFetchingChanged?(isFetching) } }
    }

    /// The live client, if connected — used by one-shot actions (start/stop/etc.).
    var activeClient: TransmissionClient? { client }

    /// The daemon's default download directory (from `session-get`), used to
    /// prefill the Add-torrent destination. Updated on each session handshake.
    private(set) var defaultDownloadDir: String?

    /// Free space (bytes) for `defaultDownloadDir`, refreshed on each poll.
    private(set) var freeSpace: Int64?
    private var loopTask: Task<Void, Never>?
    private var paused = false
    /// Set once the first handshake succeeds. Until then, connection errors keep
    /// the state at `.connecting` (the loop retries) rather than `.failed`, so the
    /// first paint never shows an offline/error message.
    private var hasConnectedOnce = false
    private(set) var state: State = .idle {
        didSet { if oldValue != state { onState?(state) } }
    }

    init(config: AppConfig) {
        self.config = config
        self.selectedServerName = Self.resolveSelectedName(config: config)
    }

    /// Resolve which server to connect to: persisted UserDefaults selection (if it
    /// still exists) → `config.currentServer` → the first server.
    private static func resolveSelectedName(config: AppConfig) -> String {
        if let saved = UserDefaults.standard.string(forKey: selectedServerKey),
           config.server(named: saved) != nil {
            return saved
        }
        if let current = config.currentServer, config.server(named: current) != nil {
            return current
        }
        return config.servers.first?.name ?? ServerConfig.localhost.name
    }

    /// The active server, resolved from `selectedServerName` (falling back to the
    /// first server if the name somehow no longer matches).
    private var activeServer: ServerConfig {
        config.server(named: selectedServerName)
            ?? config.servers.first ?? .localhost
    }

    /// The active server's display name.
    var currentServerName: String { selectedServerName }

    /// All configured server names, for the Server menu.
    var availableServerNames: [String] { config.serverNames }

    /// Switch to a different server by name: persist the choice and restart.
    func selectServer(named name: String) {
        guard config.server(named: name) != nil, name != selectedServerName else { return }
        selectedServerName = name
        UserDefaults.standard.set(name, forKey: Self.selectedServerKey)
        restart()
    }

    /// Swap in a new config (after "Reload Config") and restart the loop. If the
    /// previously selected server no longer exists, fall back to the resolved default.
    func updateConfig(_ config: AppConfig) {
        self.config = config
        if config.server(named: selectedServerName) == nil {
            selectedServerName = Self.resolveSelectedName(config: config)
        }
        restart()
    }

    func start() {
        restart()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Pause/resume polling without tearing down the connection — used when the
    /// window is hidden or minimized.
    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
    }

    /// Force an immediate refresh (e.g. right after an action). If the poll fails,
    /// drop the client so the loop re-resolves a reachable host next tick.
    func refreshNow() {
        guard let client else { return }
        Task { if !(await self.poll(client: client)) { self.client = nil } }
    }

    /// The host candidate currently in use (after failover resolution), for status.
    private(set) var resolvedServer: ServerConfig?

    /// Per-candidate probe timeout. Short so a dead host (e.g. an off-LAN IP)
    /// fails over quickly; a reachable host answers in well under this.
    private let probeTimeout: TimeInterval = 5

    private func restart() {
        stop()
        client = nil
        resolvedServer = nil
        state = .connecting
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if client == nil {
                await resolveReachableClient()
            }
            if let client, !paused {
                if !(await poll(client: client)) {
                    // Lost the connection — re-resolve (the network may have
                    // changed, e.g. left the tailnet) on the next iteration.
                    self.client = nil
                }
            }
            let seconds = config.refreshSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// Probe the active server's host candidates in order and adopt the first that
    /// answers a `session-get`. Sets `client`/`resolvedServer`/state on success.
    private func resolveReachableClient() async {
        isFetching = true
        defer { isFetching = false }

        let candidates = activeServer.connectionCandidates
        var lastError: Error?
        for candidate in candidates {
            if Task.isCancelled { return }
            do {
                let client = try TransmissionClient(server: candidate, timeout: probeTimeout)
                let info = try await client.fetchSession()
                self.client = client
                self.resolvedServer = candidate
                defaultDownloadDir = info.downloadDir
                hasConnectedOnce = true
                state = .connected(version: info.version)
                return
            } catch {
                lastError = error
                continue
            }
        }

        // No candidate responded. Before the first-ever success, stay `.connecting`
        // (the loop keeps retrying) so the first paint never flashes an error.
        let detail = (lastError as? LocalizedError)?.errorDescription
            ?? lastError?.localizedDescription
            ?? "Could not reach any configured host."
        let message = candidates.count > 1
            ? "Could not reach any of the \(candidates.count) configured hosts. \(detail)"
            : detail
        state = hasConnectedOnce ? .failed(message) : .connecting
    }

    /// Poll torrents (+ free space). Returns false if the request failed, so the
    /// caller can re-resolve a reachable host.
    @discardableResult
    private func poll(client: TransmissionClient) async -> Bool {
        isFetching = true
        defer { isFetching = false }
        do {
            let torrents = try await client.fetchTorrents()
            if let dir = defaultDownloadDir {
                freeSpace = try? await client.freeSpace(path: dir)
            }
            onTorrents?(torrents)
            return true
        } catch {
            state = hasConnectedOnce
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .connecting
            return false
        }
    }
}
