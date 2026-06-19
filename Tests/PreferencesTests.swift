import XCTest

final class PreferencesTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Decoding defaults

    func testServerConfigDefaults() throws {
        let s = try JSONDecoder().decode(ServerConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(s.host, "localhost")
        XCTAssertEqual(s.port, 9091)
        XCTAssertEqual(s.name, "localhost:9091")
        XCTAssertFalse(s.useHTTPS)
        XCTAssertEqual(s.rpcPath, "/transmission/rpc")
        XCTAssertNil(s.username)
        XCTAssertNil(s.password)
        // Backward-compatible: configs predating path mappings decode to empty.
        XCTAssertEqual(s.pathMappings, [])
    }

    func testServerConfigDecodesPathMappings() throws {
        let json = #"""
        {"name":"N","host":"h","pathMappings":[{"remote":"/video","local":"/Volumes/Video"}]}
        """#
        let s = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        XCTAssertEqual(s.pathMappings, [PathMapping(remote: "/video", local: "/Volumes/Video")])
    }

    func testPathMappingsSurviveEncodeDecodeRoundTrip() throws {
        let server = ServerConfig(
            name: "N", host: "h", port: 9091, useHTTPS: false,
            rpcPath: "/transmission/rpc",
            pathMappings: [PathMapping(remote: "/video", local: "/Volumes/Video"),
                           PathMapping(remote: "/undupe", local: "/Volumes/undupe")])
        let data = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: data), server)
    }

    func testAppConfigFallsBackToLocalhostWhenEmpty() throws {
        let cfg = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"servers":[]}"#.utf8))
        XCTAssertEqual(cfg.servers, [.localhost])
        XCTAssertEqual(cfg.refreshSeconds, 4)
    }

    func testAppConfigClampsRefresh() throws {
        let cfg = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"refreshSeconds":0}"#.utf8))
        XCTAssertEqual(cfg.refreshSeconds, 1)
    }

    func testServerLookupAndNames() {
        let cfg = AppConfig(
            servers: [.localhost, ServerConfig(name: "Remote", host: "h", port: 1,
                                               useHTTPS: true, rpcPath: "/x")],
            refreshSeconds: 5, currentServer: "Remote")
        XCTAssertEqual(cfg.serverNames, ["localhost", "Remote"])
        XCTAssertEqual(cfg.server(named: "Remote")?.host, "h")
        XCTAssertNil(cfg.server(named: "nope"))
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTrip() throws {
        let original = AppConfig(
            servers: [
                ServerConfig(name: "A", host: "a.local", port: 9091,
                             useHTTPS: false, rpcPath: "/transmission/rpc",
                             username: "u", password: "p"),
                ServerConfig(name: "B", host: "b.local", port: 8080,
                             useHTTPS: true, rpcPath: "/rpc"),
            ],
            refreshSeconds: 7, currentServer: "B")
        let data = try PreferencesStore.encode(original)
        let decoded = try PreferencesStore.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testSaveThenLoad() throws {
        let store = tmp.appendingPathComponent("preferences.json")
        let cfg = AppConfig(servers: [ServerConfig(name: "X", host: "x", port: 1,
                                                   useHTTPS: false, rpcPath: "/r")],
                            refreshSeconds: 3, currentServer: "X")
        try PreferencesStore.save(cfg, to: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        let loaded = try PreferencesStore.load(storeURL: store, legacyURL: nil)
        XCTAssertEqual(loaded, cfg)
    }

    // MARK: - Migration

    func testMigratesFromLegacyJSONC() throws {
        let legacy = tmp.appendingPathComponent("config.jsonc")
        let jsonc = """
        // Legacy config with comments and a trailing comma
        {
            "servers": [
                { "name": "Home", "host": "10.0.0.2", "port": 9091, "username": "me", "password": "secret" },
            ],
            "currentServer": "Home",
            "refreshSeconds": 6,
        }
        """
        try jsonc.write(to: legacy, atomically: true, encoding: .utf8)

        let store = tmp.appendingPathComponent("preferences.json")
        let cfg = try PreferencesStore.load(storeURL: store, legacyURL: legacy)

        XCTAssertEqual(cfg.servers.count, 1)
        XCTAssertEqual(cfg.servers.first?.name, "Home")
        XCTAssertEqual(cfg.servers.first?.host, "10.0.0.2")
        XCTAssertEqual(cfg.servers.first?.username, "me")
        XCTAssertEqual(cfg.currentServer, "Home")
        XCTAssertEqual(cfg.refreshSeconds, 6)
        // Migration writes the native store so the legacy file isn't read again.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
    }

    func testSeedsDefaultWhenNothingExists() throws {
        let store = tmp.appendingPathComponent("preferences.json")
        let cfg = try PreferencesStore.load(storeURL: store, legacyURL: nil)
        XCTAssertEqual(cfg, .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
    }

    func testNativeStoreTakesPrecedenceOverLegacy() throws {
        // When both exist, the native store wins (no re-migration).
        let store = tmp.appendingPathComponent("preferences.json")
        let native = AppConfig(servers: [ServerConfig(name: "Native", host: "n", port: 1,
                                                      useHTTPS: false, rpcPath: "/r")],
                               refreshSeconds: 2, currentServer: "Native")
        try PreferencesStore.save(native, to: store)

        let legacy = tmp.appendingPathComponent("config.jsonc")
        try #"{"servers":[{"name":"Legacy","host":"l","port":1}]}"#
            .write(to: legacy, atomically: true, encoding: .utf8)

        let loaded = try PreferencesStore.load(storeURL: store, legacyURL: legacy)
        XCTAssertEqual(loaded.servers.first?.name, "Native")
    }
}
