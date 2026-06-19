import Foundation

/// One remote→local path-mapping rule for a server. The remote daemon reports a
/// torrent's `downloadDir` as a path on *its* filesystem (e.g. `/video/...`); a
/// mapping rewrites that prefix to a path the Mac can open (e.g. `/Volumes/Video`).
///
/// Ported from the legacy app's per-connection `PathMap` (`main.pas`
/// `MapRemoteToLocal`). Stored per `ServerConfig`; edited as `remote=local` lines
/// in the Settings screen.
struct PathMapping: Codable, Sendable, Equatable {
    var remote: String
    var local: String
}

extension PathMapping {
    /// Parse the Settings text editor's contents (one `remote=local` per line) into
    /// mappings. Splits each line on the **first** `=`, trims both sides, and drops
    /// blank or `=`-less lines (mirrors the Pascal load that purges empty values).
    static func parse(_ text: String) -> [PathMapping] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let remote = line[..<eq].trimmingCharacters(in: .whitespaces)
            let local = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !remote.isEmpty, !local.isEmpty else { return nil }
            return PathMapping(remote: remote, local: local)
        }
    }

    /// Render mappings back to editor text — one `remote=local` per line.
    static func format(_ mappings: [PathMapping]) -> String {
        mappings.map { "\($0.remote)=\($0.local)" }.joined(separator: "\n")
    }
}

extension ServerConfig {
    /// Translate a remote absolute path to a local one using this server's
    /// mappings, in order (first match wins). Returns `nil` when no mapping applies.
    ///
    /// Faithful port of `main.pas` `MapRemoteToLocal`: an exact match returns the
    /// local path as-is; a prefix match (guarded by a trailing `/`, so `/var` does
    /// not match `/var2`) appends the remainder of the remote path to the local
    /// base. Case-sensitive. Both sides use `/` on macOS, so the Pascal
    /// `FixSeparators` step reduces to a trim.
    func mapRemoteToLocal(_ remotePath: String) -> String? {
        let fn = remotePath.trimmingCharacters(in: .whitespaces)
        guard !fn.isEmpty else { return nil }
        for mapping in pathMappings {
            let remote = mapping.remote.trimmingCharacters(in: .whitespaces)
            guard !remote.isEmpty else { continue }
            let local = mapping.local.trimmingCharacters(in: .whitespaces)
            if remote == fn { return local }
            let remoteWithSlash = remote.hasSuffix("/") ? remote : remote + "/"
            if fn.hasPrefix(remoteWithSlash) {
                let remainder = fn.dropFirst(remoteWithSlash.count)
                let base = local.hasSuffix("/") ? String(local.dropLast()) : local
                return base + "/" + remainder
            }
        }
        return nil
    }
}
