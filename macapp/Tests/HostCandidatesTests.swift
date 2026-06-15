import XCTest

final class HostCandidatesTests: XCTestCase {
    private func base(_ host: String, useHTTPS: Bool = false, port: Int = 9091,
                      rpcPath: String = "/transmission/rpc") -> ServerConfig {
        ServerConfig(name: "S", host: host, port: port, useHTTPS: useHTTPS,
                     rpcPath: rpcPath, username: "u", password: "p")
    }

    // MARK: - Splitting

    func testSingleHostYieldsOneCandidate() {
        let cands = base("10.0.1.2").connectionCandidates
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].host, "10.0.1.2")
        XCTAssertEqual(cands[0].port, 9091)
        XCTAssertFalse(cands[0].useHTTPS)
    }

    func testCommaSeparatedYieldsMultiple() {
        let cands = base("10.0.1.2, n5.local, host3").connectionCandidates
        XCTAssertEqual(cands.map(\.host), ["10.0.1.2", "n5.local", "host3"])
    }

    func testWhitespaceAndEmptyTokensTrimmed() {
        let cands = base("  a , , b ,").connectionCandidates
        XCTAssertEqual(cands.map(\.host), ["a", "b"])
    }

    func testNewlineSeparatedTokens() {
        let cands = base("a\nb\r\nc").connectionCandidates
        XCTAssertEqual(cands.map(\.host), ["a", "b", "c"])
    }

    func testMixedCommaAndNewlineSeparators() {
        let cands = base("a,\nb , c\n").connectionCandidates
        XCTAssertEqual(cands.map(\.host), ["a", "b", "c"])
    }

    func testEmptyHostYieldsSelf() {
        let cands = base("").connectionCandidates
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].host, "")
    }

    func testHasMultipleHostCandidates() {
        XCTAssertTrue(base("a, b").hasMultipleHostCandidates)
        XCTAssertFalse(base("a").hasMultipleHostCandidates)
    }

    // MARK: - Inheritance

    func testCandidatesInheritBaseFields() {
        let cands = base("a, b", useHTTPS: true, port: 8080, rpcPath: "/rpc").connectionCandidates
        for c in cands {
            XCTAssertTrue(c.useHTTPS)
            XCTAssertEqual(c.port, 8080)
            XCTAssertEqual(c.rpcPath, "/rpc")
            XCTAssertEqual(c.username, "u")
            XCTAssertEqual(c.password, "p")
        }
    }

    // MARK: - Per-token overrides

    func testSchemeOverridesHTTPS() {
        let cands = base("10.0.1.2, https://tail.example.ts.net").connectionCandidates
        XCTAssertFalse(cands[0].useHTTPS)              // bare host inherits (HTTP)
        XCTAssertTrue(cands[1].useHTTPS)               // https:// token
        XCTAssertEqual(cands[1].host, "tail.example.ts.net")
    }

    func testHTTPSchemeForcesPlain() {
        let cands = base("http://insecure.host", useHTTPS: true).connectionCandidates
        XCTAssertFalse(cands[0].useHTTPS)
        XCTAssertEqual(cands[0].host, "insecure.host")
    }

    func testPortOverride() {
        let cands = base("host:1234").connectionCandidates
        XCTAssertEqual(cands[0].host, "host")
        XCTAssertEqual(cands[0].port, 1234)
    }

    func testPathOverride() {
        let cands = base("https://host:443/custom/rpc").connectionCandidates
        XCTAssertEqual(cands[0].host, "host")
        XCTAssertEqual(cands[0].port, 443)
        XCTAssertTrue(cands[0].useHTTPS)
        XCTAssertEqual(cands[0].rpcPath, "/custom/rpc")
    }

    func testBarePathSlashKeepsDefault() {
        let cands = base("host/", rpcPath: "/transmission/rpc").connectionCandidates
        XCTAssertEqual(cands[0].host, "host")
        XCTAssertEqual(cands[0].rpcPath, "/transmission/rpc")   // lone "/" ignored
    }

    func testFullConnectionString() {
        let cands = base("http://1.2.3.4:9091/transmission/rpc, https://tail.ts.net")
            .connectionCandidates
        XCTAssertEqual(cands[0].host, "1.2.3.4")
        XCTAssertEqual(cands[0].port, 9091)
        XCTAssertFalse(cands[0].useHTTPS)
        XCTAssertEqual(cands[0].rpcPath, "/transmission/rpc")
        XCTAssertEqual(cands[1].host, "tail.ts.net")
        XCTAssertTrue(cands[1].useHTTPS)
        XCTAssertEqual(cands[1].port, 9091)                     // inherited
    }

    func testBracketedIPv6WithPort() {
        let cands = base("[::1]:9092").connectionCandidates
        XCTAssertEqual(cands[0].host, "::1")
        XCTAssertEqual(cands[0].port, 9092)
    }

    func testBareIPv6NotSplitAsPort() {
        let cands = base("fe80::1", port: 9091).connectionCandidates
        XCTAssertEqual(cands[0].host, "fe80::1")   // multiple colons → not a port
        XCTAssertEqual(cands[0].port, 9091)
    }

    func testTheOwnersRealScenario() {
        // The exact use case from the feature request.
        let cands = base("10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net")
            .connectionCandidates
        XCTAssertEqual(cands.count, 3)
        XCTAssertEqual(cands[0].host, "10.0.1.2");   XCTAssertFalse(cands[0].useHTTPS)
        XCTAssertEqual(cands[1].host, "n5.local");   XCTAssertFalse(cands[1].useHTTPS)
        XCTAssertEqual(cands[2].host, "transmission.raptor-ruffe.ts.net")
        XCTAssertTrue(cands[2].useHTTPS)
        XCTAssertTrue(cands.allSatisfy { $0.port == 9091 && $0.username == "u" })
    }
}
