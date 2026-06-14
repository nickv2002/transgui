import XCTest

final class ConnectionResolverTests: XCTestCase {
    private func server(_ host: String) -> ServerConfig {
        ServerConfig(name: host, host: host, port: 9091,
                     useHTTPS: false, rpcPath: "/transmission/rpc")
    }

    func testPicksFirstReachable() async {
        let cands = [server("a"), server("b"), server("c")]
        // Only "b" and "c" respond → should pick "b" (first reachable in order).
        let reachable: Set<String> = ["b", "c"]
        let chosen = await ConnectionResolver.firstReachable(cands) { reachable.contains($0.host) }
        XCTAssertEqual(chosen?.host, "b")
    }

    func testPrefersEarlierWhenAllReachable() async {
        let cands = [server("a"), server("b")]
        let chosen = await ConnectionResolver.firstReachable(cands) { _ in true }
        XCTAssertEqual(chosen?.host, "a")
    }

    func testReturnsNilWhenNoneReachable() async {
        let cands = [server("a"), server("b")]
        let chosen = await ConnectionResolver.firstReachable(cands) { _ in false }
        XCTAssertNil(chosen)
    }

    func testSkipsDeadLeadingCandidates() async {
        // Mirrors "off the tailnet": the first two hosts are down, the last works.
        let cands = [server("tail.ts.net"), server("10.0.1.2"), server("n5.local")]
        let chosen = await ConnectionResolver.firstReachable(cands) { $0.host == "n5.local" }
        XCTAssertEqual(chosen?.host, "n5.local")
    }

    func testProbesInOrderAndStopsAtFirstSuccess() async {
        let cands = [server("a"), server("b"), server("c")]
        var probed: [String] = []
        let chosen = await ConnectionResolver.firstReachable(cands) { s in
            probed.append(s.host)
            return s.host == "b"
        }
        XCTAssertEqual(chosen?.host, "b")
        XCTAssertEqual(probed, ["a", "b"])   // never probes "c" after "b" succeeds
    }

    func testEmptyCandidatesReturnsNil() async {
        let chosen = await ConnectionResolver.firstReachable([]) { _ in true }
        XCTAssertNil(chosen)
    }
}
