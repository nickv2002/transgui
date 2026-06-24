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

    /// The active server's full config — used by the torrent actions to map a
    /// remote download path to a local one (`pathMappings`).
    var activeServerConfig: ServerConfig { activeServer }

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

    /// Tighter timeout for the single "last-good host" fast-path probe, so a host
    /// that has since become unreachable doesn't delay falling back to racing.
    private let fastPathTimeout: TimeInterval = 1.5

    /// Set once the first torrent list has been fetched. The very first poll after
    /// a fresh connect requests a slim field set (`Torrent.firstFetchFields`) for a
    /// faster cold paint; subsequent polls request the full set.
    private var hasFetchedTorrentsOnce = false

    /// The reachable client + its session info from a successful probe. `Sendable`
    /// so the winning concurrent probe can hand the already-connected client back.
    private struct ResolvedConnection: Sendable {
        let client: TransmissionClient
        let server: ServerConfig
        let info: SessionInfo
    }

    /// UserDefaults key for the host that last answered for the active server, so
    /// the next launch can try it first (one quick probe) before racing all hosts.
    private var lastGoodHostKey: String { "LastGoodHost.\(selectedServerName)" }

    private func restart() {
        stop()
        client = nil
        resolvedServer = nil
        hasFetchedTorrentsOnce = false
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

        let started = Date()
        let candidates = activeServer.connectionCandidates

        // Fast path: try the host that worked last time, alone, with a tight
        // timeout. The common case (still reachable) connects in one round-trip
        // without spinning up a client per candidate.
        if let saved = UserDefaults.standard.string(forKey: lastGoodHostKey),
           let lastGood = candidates.first(where: { $0.host == saved }),
           !Task.isCancelled,
           let resolved = await Self.probe(lastGood, timeout: fastPathTimeout) {
            adopt(resolved)
            perfLog("resolved in \(ms(since: started)) via \(endpoint(resolved.server)) (fast-path)")
            return
        }

        if Task.isCancelled { return }

        // Race every candidate concurrently; the fastest responder wins, so a
        // dead/hanging host never blocks a reachable one behind it.
        let raced = await ConnectionResolver.firstToRespond(candidates) { [probeTimeout] candidate in
            await Self.probe(candidate, timeout: probeTimeout)
        }
        if let raced {
            adopt(raced)
            perfLog("resolved in \(ms(since: started)) via \(endpoint(raced.server)) (raced \(candidates.count))")
            return
        }

        // No candidate responded. Before the first-ever success, stay `.connecting`
        // (the loop keeps retrying) so the first paint never flashes an error.
        let detail = "Could not reach any configured host."
        let message = candidates.count > 1
            ? "Could not reach any of the \(candidates.count) configured hosts. \(detail)"
            : detail
        state = hasConnectedOnce ? .failed(message) : .connecting
    }

    /// Adopt a resolved connection as the live client and publish connected state.
    private func adopt(_ resolved: ResolvedConnection) {
        client = resolved.client
        resolvedServer = resolved.server
        defaultDownloadDir = resolved.info.downloadDir
        hasConnectedOnce = true
        UserDefaults.standard.set(resolved.server.host, forKey: lastGoodHostKey)
        state = .connected(version: resolved.info.version)
    }

    /// Build a client for `candidate`, run `session-get`, and return the connected
    /// client on success or nil on any failure. `nonisolated static` so it is
    /// `Sendable`-safe to call from concurrent probe tasks.
    nonisolated private static func probe(_ candidate: ServerConfig, timeout: TimeInterval) async -> ResolvedConnection? {
        do {
            let client = try TransmissionClient(server: candidate, timeout: timeout)
            let info = try await client.fetchSession()
            return ResolvedConnection(client: client, server: candidate, info: info)
        } catch {
            return nil
        }
    }

    private func ms(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000))ms"
    }

    private func endpoint(_ s: ServerConfig) -> String {
        "\(s.useHTTPS ? "https" : "http")://\(s.host):\(s.port)"
    }

    /// Poll torrents (+ free space). Returns false if the request failed, so the
    /// caller can re-resolve a reachable host.
    @discardableResult
    private func poll(client: TransmissionClient) async -> Bool {
        isFetching = true
        defer { isFetching = false }

        // The first poll after a fresh connect uses a slim field set for a faster
        // cold paint; later polls fetch the full set (so trackers/comment/etc. fill
        // in).
        let firstFetch = !hasFetchedTorrentsOnce
        let fields = firstFetch ? Torrent.firstFetchFields : Torrent.requestedFields
        let started = Date()

        do {
            // Fetch torrents and free space concurrently so free space no longer
            // adds a serial round-trip in front of the first paint.
            let dir = defaultDownloadDir
            async let torrentsTask = client.fetchTorrents(fields: fields)
            async let freeTask: Int64? = {
                guard let dir else { return nil }
                return try? await client.freeSpace(path: dir)
            }()
            let torrents = try await torrentsTask
            freeSpace = await freeTask
            if firstFetch {
                perfLog("first list: \(torrents.count) torrents, fetch \(ms(since: started)) (slim)")
                hasFetchedTorrentsOnce = true
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
