import Foundation

/// Turns a failed connection attempt into a human-readable, field-targeted
/// message for the Settings "Test Connection" alert — so the user can tell
/// whether the host/port, the HTTPS toggle, the RPC path, or the credentials are
/// at fault. Pure (Foundation-only) so it can be unit-tested.
enum ConnectionDiagnostics {
    static func message(for error: Error, server: ServerConfig) -> String {
        let scheme = server.useHTTPS ? "HTTPS" : "HTTP"
        guard let te = error as? TransmissionError else {
            return error.localizedDescription
        }
        switch te {
        case .invalidURL:
            return "The host, port, or RPC path don’t form a valid URL. Check those fields."
        case .connectionFailed(let detail):
            return "Couldn’t reach \(server.host):\(server.port) over \(scheme). "
                + "Check the host, port, and the Use HTTPS setting (and that the daemon is running).\n\n\(detail)"
        case .authenticationFailed:
            return "Reached the server, but authentication was rejected (HTTP 401). "
                + "Check the username and password."
        case .httpError(404):
            return "Reached the server, but found no Transmission RPC at “\(server.rpcPath)” (HTTP 404). "
                + "Check the RPC Path."
        case .httpError(let code):
            return "Reached the server, but it returned HTTP \(code). "
                + "Check the RPC Path and that this is a Transmission daemon."
        case .rpcError(let message):
            return "Connected, but the server reported an error: \(message)."
        case .decodingFailed:
            return "Reached the server, but its response wasn’t valid Transmission RPC. "
                + "Check the RPC Path and HTTPS setting."
        }
    }
}
