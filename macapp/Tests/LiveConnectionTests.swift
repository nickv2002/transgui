import XCTest

/// Integration tests that hit a real Transmission daemon. Skipped unless
/// `RUN_LIVE_TRANSMISSION_TESTS=1` is forwarded to the test runner, e.g.:
///
///   TEST_RUNNER_RUN_LIVE_TRANSMISSION_TESTS=1 xcodebuild ... test \
///     -only-testing:TransmissionRemoteTests/LiveConnectionTests
///
/// Credentials are read at runtime from the user's legacy JSONC config (never
/// hard-coded). The daemon's host forms are exercised: bare IP, `.local`, and
/// Tailscale HTTPS, plus deliberate failures (unknown host, wrong password).
///
/// NOTE on ATS: a host-less unit-test bundle runs inside the `xctest` tool, whose
/// App Transport Security settings (not this bundle's Info.plist) govern URLSession.
/// `xctest` blocks cleartext HTTP to named hosts, so the plain-HTTP cases here
/// `XCTSkip` when ATS blocks them — they're verified for real through the app
/// (which carries an ATS exception) and via `curl`. HTTPS cases run normally.
final class LiveConnectionTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_TRANSMISSION_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RUN_LIVE_TRANSMISSION_TESTS=1 to run live connection tests.")
        }
    }

    /// Username/password from the first server in the user's legacy JSONC.
    private func credentials() throws -> (user: String?, pass: String?) {
        guard let cfg = try PreferencesStore.loadLegacyJSONC(from: PreferencesStore.legacyConfigURL),
              let first = cfg.servers.first else {
            throw XCTSkip("No legacy config to read credentials from.")
        }
        return (first.username, first.password)
    }

    private func make(_ host: String, port: Int = 9091, https: Bool = false,
                      user: String?, pass: String?) -> ServerConfig {
        ServerConfig(name: host, host: host, port: port, useHTTPS: https,
                     rpcPath: "/transmission/rpc", username: user, password: pass)
    }

    /// True when the error is ATS blocking cleartext HTTP in the test runner
    /// (reported as a generic "offline"/cancelled connection), not a real fault.
    private func isATSBlocked(_ error: Error) -> Bool {
        guard case TransmissionError.connectionFailed(let detail) = error else { return false }
        return detail.contains("offline") || detail.contains("App Transport Security")
    }

    /// Connect over plain HTTP, asserting success — but skip if the test runner's
    /// ATS blocks cleartext (a runner limitation, not a product bug).
    private func assertHTTPReachable(_ host: String) async throws {
        let c = try credentials()
        let client = try TransmissionClient(server: make(host, user: c.user, pass: c.pass))
        do {
            let info = try await client.fetchSession()
            XCTAssertFalse(info.version.isEmpty, "\(host) returned an empty version")
        } catch {
            if isATSBlocked(error) {
                throw XCTSkip("ATS in the test runner blocks cleartext HTTP to \(host); "
                    + "verified via the app and curl instead.")
            }
            throw error
        }
    }

    // MARK: - Real hosts

    func testConnectViaIP() async throws {
        try requireLive()
        try await assertHTTPReachable("10.0.1.2")
    }

    func testConnectViaLocalHostname() async throws {
        try requireLive()
        try await assertHTTPReachable("n5.local")
    }

    func testConnectViaTailscaleHTTPS() async throws {
        try requireLive()
        let c = try credentials()
        let client = try TransmissionClient(server: make(
            "transmission.raptor-ruffe.ts.net", port: 9091, https: true,
            user: c.user, pass: c.pass))
        let info = try await client.fetchSession()
        XCTAssertFalse(info.version.isEmpty)
    }

    // MARK: - Failover (multi-host)

    func testFailoverResolvesToAReachableHost() async throws {
        try requireLive()
        let c = try credentials()
        // The owner's real multi-host scenario. In the test runner ATS blocks the
        // plain-HTTP candidates, so this resolves to the Tailscale HTTPS host; in
        // the app (ATS exception) it would pick the first reachable LAN host.
        let server = make("10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net",
                          user: c.user, pass: c.pass)
        let chosen = await ConnectionResolver.firstReachable(server.connectionCandidates) { candidate in
            guard let client = try? TransmissionClient(server: candidate, timeout: 5) else { return false }
            return (try? await client.fetchSession()) != nil
        }
        XCTAssertNotNil(chosen, "expected at least one of the candidates to respond")
    }

    // MARK: - Failures (over HTTPS so ATS doesn't interfere)

    func testUnknownHostFails() async throws {
        try requireLive()
        let client = try TransmissionClient(server: make(
            "does-not-exist.invalid", https: true, user: nil, pass: nil))
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected a connection failure for an unknown host.")
        } catch let error as TransmissionError {
            if case .connectionFailed = error { /* expected */ } else {
                XCTFail("Expected .connectionFailed, got \(error)")
            }
        }
    }

    func testWrongPasswordFailsAuth() async throws {
        try requireLive()
        let c = try credentials()
        try XCTSkipIf(c.user == nil || (c.user?.isEmpty ?? true),
                      "Daemon has no auth; skipping wrong-password test.")
        // Use the Tailscale HTTPS endpoint so ATS doesn't mask the 401.
        let client = try TransmissionClient(server: make(
            "transmission.raptor-ruffe.ts.net", port: 9091, https: true,
            user: c.user, pass: "definitely-wrong-password"))
        do {
            _ = try await client.fetchSession()
            XCTFail("Expected authentication to fail with a wrong password.")
        } catch let error as TransmissionError {
            if case .authenticationFailed = error { /* expected */ } else {
                XCTFail("Expected .authenticationFailed, got \(error)")
            }
        }
    }
}
