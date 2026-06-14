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

    /// Force an immediate refresh (e.g. right after an action).
    func refreshNow() {
        guard let client else { return }
        Task { await self.poll(client: client) }
    }

    private func restart() {
        stop()
        state = .connecting
        do {
            let client = try TransmissionClient(server: activeServer)
            self.client = client
            loopTask = Task { [weak self] in
                await self?.runLoop(client: client)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func runLoop(client: TransmissionClient) async {
        // Initial session handshake to confirm connectivity / surface auth errors.
        isFetching = true
        do {
            let info = try await client.fetchSession()
            defaultDownloadDir = info.downloadDir
            hasConnectedOnce = true
            state = .connected(version: info.version)
        } catch {
            // Before the first success, keep retrying as `.connecting`; only show
            // a failure once we've connected at least once.
            state = hasConnectedOnce
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .connecting
        }
        isFetching = false

        while !Task.isCancelled {
            if !paused {
                await poll(client: client)
            }
            let seconds = config.refreshSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func poll(client: TransmissionClient) async {
        isFetching = true
        defer { isFetching = false }
        do {
            let torrents = try await client.fetchTorrents()
            // A successful poll also confirms we're connected.
            if case .connected = state {} else {
                let info = try? await client.fetchSession()
                defaultDownloadDir = info?.downloadDir
                hasConnectedOnce = true
                state = .connected(version: info?.version ?? "?")
            }
            if let dir = defaultDownloadDir {
                freeSpace = try? await client.freeSpace(path: dir)
            }
            onTorrents?(torrents)
        } catch {
            // Same first-connect grace as the initial handshake.
            state = hasConnectedOnce
                ? .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : .connecting
        }
    }
}
