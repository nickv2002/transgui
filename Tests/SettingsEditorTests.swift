import XCTest

final class SettingsEditorTests: XCTestCase {
    private func sample() -> AppConfig {
        AppConfig(
            servers: [
                ServerConfig(name: "A", host: "a.local", port: 9091,
                             useHTTPS: false, rpcPath: "/transmission/rpc",
                             username: "u", password: "p"),
                ServerConfig(name: "B", host: "b.local", port: 8080,
                             useHTTPS: true, rpcPath: "/rpc"),
            ],
            refreshSeconds: 4, currentServer: "A")
    }

    private func server(_ name: String, host: String = "h") -> ServerConfig {
        ServerConfig(name: name, host: host, port: 9091,
                     useHTTPS: false, rpcPath: "/transmission/rpc")
    }

    // MARK: - Dirty / save

    func testFreshEditorNotDirty() {
        let e = SettingsEditor(sample())
        XCTAssertFalse(e.isDirty)
    }

    func testEditMakesDirtyAndSaveClears() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "changed.local"), normalizeName: true)
        XCTAssertTrue(e.isDirty)
        let saved = e.save()
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(saved.servers[0].host, "changed.local")
        XCTAssertEqual(e.servers[0].host, "changed.local")
    }

    func testPathMappingsFlowThroughUpdateAndSave() {
        var e = SettingsEditor(sample())
        var edited = server("A", host: "a.local")
        edited.pathMappings = [PathMapping(remote: "/video", local: "/Volumes/Video")]
        e.updateServer(at: 0, to: edited, normalizeName: true)
        XCTAssertTrue(e.isDirty)               // a mappings change makes the editor dirty
        let saved = e.save()
        XCTAssertEqual(saved.servers[0].pathMappings,
                       [PathMapping(remote: "/video", local: "/Volumes/Video")])
        XCTAssertFalse(e.isDirty)
    }

    func testResetRevertsToBaseline() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "x"), normalizeName: true)
        XCTAssertTrue(e.isDirty)
        e.reset(to: sample())
        XCTAssertFalse(e.isDirty)
        XCTAssertEqual(e.servers[0].host, "a.local")
    }

    // MARK: - Add

    func testAddServerAppendsUniqueName() {
        var e = SettingsEditor(sample())
        let i = e.addServer()
        XCTAssertEqual(i, 2)
        XCTAssertEqual(e.serverCount, 3)
        XCTAssertEqual(e.servers[2].name, "New Server")
        XCTAssertTrue(e.isDirty)
    }

    func testAddServerDisambiguatesName() {
        var e = SettingsEditor(AppConfig(servers: [server("New Server")],
                                         refreshSeconds: 4, currentServer: "New Server"))
        let i = e.addServer()
        XCTAssertEqual(e.servers[i].name, "New Server 2")
        let j = e.addServer()
        XCTAssertEqual(e.servers[j].name, "New Server 3")
    }

    // MARK: - Remove

    func testRemoveServer() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 1)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertEqual(e.servers[0].name, "A")
    }

    func testRemoveLastServerIsNoOp() {
        var e = SettingsEditor(AppConfig(servers: [server("only")],
                                         refreshSeconds: 4, currentServer: "only"))
        e.removeServer(at: 0)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertFalse(e.isDirty)
    }

    func testRemoveInvalidIndexIsNoOp() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 9)
        XCTAssertEqual(e.serverCount, 2)
    }

    func testRemovingDefaultRepointsToFirst() {
        var e = SettingsEditor(sample())   // default = "A" at index 0
        e.removeServer(at: 0)
        XCTAssertEqual(e.serverCount, 1)
        XCTAssertEqual(e.currentServer, "B")   // fell back to first remaining
    }

    func testDeleteThenSave() {
        var e = SettingsEditor(sample())
        e.removeServer(at: 1)
        let saved = e.save()
        XCTAssertEqual(saved.servers.count, 1)
        XCTAssertEqual(saved.servers.first?.name, "A")
        XCTAssertFalse(e.isDirty)
    }

    // MARK: - Update (normalize on end-edit)

    func testUpdateTrimsAndKeepsNonEmptyName() {
        var e = SettingsEditor(sample())
        let stored = e.updateServer(at: 0, to: server("  Renamed  "), normalizeName: true)
        XCTAssertEqual(stored.name, "Renamed")
        XCTAssertEqual(e.servers[0].name, "Renamed")
    }

    func testUpdateEmptyNameFallsBackToOld() {
        var e = SettingsEditor(sample())
        let stored = e.updateServer(at: 0, to: server("   "), normalizeName: true)
        XCTAssertEqual(stored.name, "A")
    }

    func testUpdateDuplicateNameRejectedOnNormalize() {
        var e = SettingsEditor(sample())
        // Try to rename B → "A" (collides) — should keep "B".
        let stored = e.updateServer(at: 1, to: server("A"), normalizeName: true)
        XCTAssertEqual(stored.name, "B")
        XCTAssertEqual(e.servers[1].name, "B")
    }

    func testRenamingDefaultFollowsTheRename() {
        var e = SettingsEditor(sample())   // default "A"
        e.updateServer(at: 0, to: server("A2"), normalizeName: true)
        XCTAssertEqual(e.currentServer, "A2")
    }

    func testUpdatePreservesOtherFields() {
        var e = SettingsEditor(sample())
        var s = server("A")
        s.host = "newhost"; s.port = 1234; s.useHTTPS = true; s.username = "x"; s.password = "y"
        e.updateServer(at: 0, to: s, normalizeName: true)
        XCTAssertEqual(e.servers[0].host, "newhost")
        XCTAssertEqual(e.servers[0].port, 1234)
        XCTAssertTrue(e.servers[0].useHTTPS)
        XCTAssertEqual(e.servers[0].username, "x")
        XCTAssertEqual(e.servers[0].password, "y")
    }

    // MARK: - Update (live, no normalize)

    func testLiveUpdateTakesRawNameEvenIfDuplicate() {
        var e = SettingsEditor(sample())
        // Live (per-keystroke) sync allows a transient duplicate / raw value.
        e.updateServer(at: 1, to: server("A"), normalizeName: false)
        XCTAssertEqual(e.servers[1].name, "A")
    }

    // MARK: - Default server + refresh

    func testSetDefaultServer() {
        var e = SettingsEditor(sample())
        e.setDefaultServer("B")
        XCTAssertEqual(e.currentServer, "B")
        XCTAssertTrue(e.isDirty)
    }

    func testSetRefreshSecondsClampedInNormalized() {
        var e = SettingsEditor(sample())
        e.setRefreshSeconds(0)
        XCTAssertEqual(e.normalized().refreshSeconds, 1)   // clamped to >= 1
        e.setRefreshSeconds(30)
        XCTAssertEqual(e.normalized().refreshSeconds, 30)
    }

    // MARK: - Combined scenario

    func testChangeAddRemoveThenSaveRoundTrip() {
        var e = SettingsEditor(sample())
        e.updateServer(at: 0, to: server("A", host: "edited"), normalizeName: true)
        let i = e.addServer()
        e.updateServer(at: i, to: server("C", host: "c.local"), normalizeName: true)
        e.removeServer(at: 1)   // remove original "B"
        e.setDefaultServer("C")
        e.setRefreshSeconds(10)
        let saved = e.save()

        XCTAssertEqual(saved.servers.map(\.name), ["A", "C"])
        XCTAssertEqual(saved.servers[0].host, "edited")
        XCTAssertEqual(saved.currentServer, "C")
        XCTAssertEqual(saved.refreshSeconds, 10)
        XCTAssertFalse(e.isDirty)
    }
}
