import XCTest

final class ConnectionDiagnosticsTests: XCTestCase {
    private let server = ServerConfig(
        name: "S", host: "host.local", port: 9091,
        useHTTPS: false, rpcPath: "/transmission/rpc",
        username: "u", password: "p")

    func testConnectionFailedMentionsHostPortAndHTTPS() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.connectionFailed("timed out"), server: server)
        XCTAssertTrue(msg.contains("host.local:9091"))
        XCTAssertTrue(msg.contains("HTTP"))
        XCTAssertTrue(msg.contains("timed out"))
    }

    func testConnectionFailedReportsHTTPSWhenEnabled() {
        var s = server
        s.useHTTPS = true
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.connectionFailed("x"), server: s)
        XCTAssertTrue(msg.contains("HTTPS"))
    }

    func testAuthFailureMentionsCredentials() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.authenticationFailed, server: server)
        XCTAssertTrue(msg.lowercased().contains("username"))
        XCTAssertTrue(msg.lowercased().contains("password"))
    }

    func test404MentionsRPCPath() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.httpError(404), server: server)
        XCTAssertTrue(msg.contains("/transmission/rpc"))
        XCTAssertTrue(msg.contains("404"))
        XCTAssertTrue(msg.contains("RPC Path"))
    }

    func testOtherHTTPErrorShowsCode() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.httpError(500), server: server)
        XCTAssertTrue(msg.contains("500"))
    }

    func testInvalidURL() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.invalidURL, server: server)
        XCTAssertTrue(msg.lowercased().contains("url"))
    }

    func testRPCError() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.rpcError("boom"), server: server)
        XCTAssertTrue(msg.contains("boom"))
    }

    func testDecodingFailureMentionsRPC() {
        let msg = ConnectionDiagnostics.message(
            for: TransmissionError.decodingFailed("bad json"), server: server)
        XCTAssertTrue(msg.contains("RPC"))
    }

    func testNonTransmissionErrorFallsBackToLocalizedDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "kaboom" } }
        let msg = ConnectionDiagnostics.message(for: Boom(), server: server)
        XCTAssertEqual(msg, "kaboom")
    }
}
