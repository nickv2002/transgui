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

    private var config: AppConfig
    private var client: TransmissionClient?

    /// The live client, if connected — used by one-shot actions (start/stop/etc.).
    var activeClient: TransmissionClient? { client }

    /// The daemon's default download directory (from `session-get`), used to
    /// prefill the Add-torrent destination. Updated on each session handshake.
    private(set) var defaultDownloadDir: String?
    private var loopTask: Task<Void, Never>?
    private var paused = false
    private(set) var state: State = .idle {
        didSet { if oldValue != state { onState?(state) } }
    }

    init(config: AppConfig) {
        self.config = config
    }

    /// Swap in a new config (after "Reload Config") and restart the loop.
    func updateConfig(_ config: AppConfig) {
        self.config = config
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
            let client = try TransmissionClient(config: config)
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
        do {
            let info = try await client.fetchSession()
            defaultDownloadDir = info.downloadDir
            state = .connected(version: info.version)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        while !Task.isCancelled {
            if !paused {
                await poll(client: client)
            }
            let seconds = config.refreshSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func poll(client: TransmissionClient) async {
        do {
            let torrents = try await client.fetchTorrents()
            // A successful poll also confirms we're connected.
            if case .connected = state {} else {
                let info = try? await client.fetchSession()
                defaultDownloadDir = info?.downloadDir
                state = .connected(version: info?.version ?? "?")
            }
            onTorrents?(torrents)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
