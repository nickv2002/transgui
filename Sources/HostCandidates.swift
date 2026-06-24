import Foundation

extension ServerConfig {
    /// Parse the (possibly comma-separated) `host` field into one `ServerConfig`
    /// per candidate endpoint, all pointing at the same logical server. Each token
    /// is a "connection string": a bare host, `host:port`, or a full
    /// `scheme://host[:port][/path]`. Parts a token omits are inherited from this
    /// server (useHTTPS, port, rpcPath, credentials, name). A single host yields a
    /// single candidate, so existing single-host configs are unchanged.
    ///
    /// Use case: enter `10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net`
    /// and the app connects to whichever responds first (e.g. the Tailscale host
    /// when off-LAN, the IP/`.local` host when on-LAN).
    var connectionCandidates: [ServerConfig] {
        let tokens = host
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [self] }   // empty host → keep as-is (fails clearly)
        return tokens.map { candidate(fromToken: $0) }
    }

    /// True when the host field lists more than one candidate.
    var hasMultipleHostCandidates: Bool {
        connectionCandidates.count > 1
    }

    /// Build a candidate `ServerConfig` from one connection-string token,
    /// inheriting any unspecified fields from `self`.
    func candidate(fromToken token: String) -> ServerConfig {
        var c = self
        var t = token.trimmingCharacters(in: .whitespaces)

        // Optional scheme: http:// or https:// overrides useHTTPS.
        if let r = t.range(of: "://") {
            let scheme = t[..<r.lowerBound].lowercased()
            if scheme == "http" { c.useHTTPS = false }
            else if scheme == "https" { c.useHTTPS = true }
            t = String(t[r.upperBound...])
        }

        // Optional path: everything from the first "/" overrides rpcPath
        // (a lone "/" is ignored so it inherits the default path).
        if let slash = t.firstIndex(of: "/") {
            let path = String(t[slash...])
            if path != "/" { c.rpcPath = path }
            t = String(t[..<slash])
        }

        // host[:port], handling bracketed IPv6 like [::1]:9091.
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            c.host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { c.port = p }
        } else if t.filter({ $0 == ":" }).count == 1,
                  let colon = t.firstIndex(of: ":"),
                  let p = Int(t[t.index(after: colon)...]) {
            c.port = p
            c.host = String(t[..<colon])
        } else {
            // 0 colons (plain host) or >1 (bare IPv6 literal) → use as-is.
            c.host = t
        }

        c.host = c.host.trimmingCharacters(in: .whitespaces)
        return c
    }
}

/// Picks the first reachable endpoint from a candidate list. Pure (the network
/// probe is injected), so failover selection is unit-tested without sockets.
enum ConnectionResolver {
    /// Probe `candidates` in order and return the first for which `probe` returns
    /// true, or nil if none respond. Order is preference order ("first that
    /// responds").
    static func firstReachable(
        _ candidates: [ServerConfig],
        probe: (ServerConfig) async -> Bool
    ) async -> ServerConfig? {
        for candidate in candidates {
            if await probe(candidate) { return candidate }
        }
        return nil
    }

    /// Probe all candidates **concurrently** and return the first probe result that
    /// is non-nil, cancelling the rest. Unlike `firstReachable`, order is irrelevant
    /// — the fastest responder wins — so a dead/hanging candidate never blocks a
    /// reachable one behind it (the cold-start latency collapses from the sum of the
    /// dead hosts' timeouts to roughly one round-trip). Pure: the network probe is
    /// injected, so selection is unit-tested without sockets. The generic payload
    /// lets the winning probe hand back an already-connected client.
    static func firstToRespond<T: Sendable>(
        _ candidates: [ServerConfig],
        probe: @Sendable @escaping (ServerConfig) async -> T?
    ) async -> T? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            for candidate in candidates {
                group.addTask { await probe(candidate) }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}
