import Foundation

/// Transmission torrent status codes (RPC spec). Mirrors the legacy app's `tsXxx`
/// constants in `rpc.pas`.
enum TorrentStatus: Int, Sendable {
    case stopped = 0
    case checkWait = 1
    case checking = 2
    case downloadWait = 3
    case downloading = 4
    case seedWait = 5
    case seeding = 6

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .checkWait: return "Queued (check)"
        case .checking: return "Checking"
        case .downloadWait: return "Queued (down)"
        case .downloading: return "Downloading"
        case .seedWait: return "Queued (seed)"
        case .seeding: return "Seeding"
        }
    }

    /// True while the daemon is actively running this torrent (not stopped).
    var isActive: Bool { self != .stopped }
}

/// Transmission `bandwidthPriority` values (RPC spec): -1 low, 0 normal, 1 high.
enum BandwidthPriority: Int, Sendable, CaseIterable {
    case low = -1
    case normal = 0
    case high = 1

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// Per-file priority (`torrent-set` `priority-low/normal/high`). Same raw values
/// as `BandwidthPriority` but a distinct type because the RPC methods differ.
enum FilePriority: Int, Sendable, CaseIterable {
    case low = -1
    case normal = 0
    case high = 1

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// One file inside a torrent, merged from the `files` and `fileStats` arrays of a
/// single-torrent `torrent-get`. `index` is the file's position in those arrays —
/// the id used by `files-wanted` / `priority-*`.
struct TorrentFile: Sendable, Equatable, Identifiable {
    let index: Int
    let name: String
    let length: Int64
    let bytesCompleted: Int64
    let wanted: Bool
    let priorityRaw: Int

    var id: Int { index }
    var percentDone: Double { length > 0 ? Double(bytesCompleted) / Double(length) : 1 }
    var priority: FilePriority { FilePriority(rawValue: priorityRaw) ?? .normal }
}

/// A single torrent as returned by `torrent-get`. Only the MVP fields are decoded.
struct Torrent: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let statusRaw: Int
    let percentDone: Double
    let totalSize: Int64
    let sizeWhenDone: Int64
    let leftUntilDone: Int64
    let rateDownload: Int64
    let rateUpload: Int64
    let eta: Int
    let uploadRatio: Double
    let downloadDir: String
    let errorString: String
    let peersConnected: Int
    let peersSendingToUs: Int
    let peersGettingFromUs: Int
    let addedDate: Double
    let hashString: String
    let queuePosition: Int
    let bandwidthPriorityRaw: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case statusRaw = "status"
        case percentDone
        case totalSize
        case sizeWhenDone
        case leftUntilDone
        case rateDownload
        case rateUpload
        case eta
        case uploadRatio
        case downloadDir
        case errorString
        case peersConnected
        case peersSendingToUs
        case peersGettingFromUs
        case addedDate
        case hashString
        case queuePosition
        case bandwidthPriorityRaw = "bandwidthPriority"
    }

    var status: TorrentStatus { TorrentStatus(rawValue: statusRaw) ?? .stopped }

    var bandwidthPriority: BandwidthPriority {
        BandwidthPriority(rawValue: bandwidthPriorityRaw) ?? .normal
    }

    /// The list of fields the MVP requests from `torrent-get`.
    static let requestedFields = [
        "id", "name", "status", "percentDone", "totalSize", "sizeWhenDone",
        "leftUntilDone", "rateDownload", "rateUpload", "eta", "uploadRatio",
        "downloadDir", "errorString", "peersConnected", "peersSendingToUs",
        "peersGettingFromUs", "addedDate", "hashString", "queuePosition",
        "bandwidthPriority",
    ]
}

/// Subset of `session-get` we care about for the MVP.
struct SessionInfo: Codable, Sendable {
    let version: String
    let downloadDir: String?

    enum CodingKeys: String, CodingKey {
        case version
        case downloadDir = "download-dir"
    }
}

// MARK: - RPC envelope

/// Generic Transmission RPC response: `{ "result": "...", "arguments": { ... } }`.
struct RPCResponse<Arguments: Decodable>: Decodable {
    let result: String
    let arguments: Arguments?
}

/// Decoded `arguments` for `torrent-get`.
struct TorrentListArguments: Decodable, Sendable {
    let torrents: [Torrent]
}

// MARK: - Files RPC decoding

/// Raw `files` array entry from a single-torrent `torrent-get`.
private struct RawFile: Decodable {
    let name: String
    let length: Int64
    let bytesCompleted: Int64
}

/// Raw `fileStats` array entry (parallel to `files`).
private struct RawFileStat: Decodable {
    let wanted: Bool
    let priority: Int
}

/// One torrent's `files` + `fileStats`, merged into `[TorrentFile]`.
struct TorrentFilesEntry: Decodable, Sendable {
    let id: Int
    let files: [TorrentFile]

    private enum CodingKeys: String, CodingKey {
        case id, files, fileStats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        let raw = try c.decode([RawFile].self, forKey: .files)
        let stats = try c.decodeIfPresent([RawFileStat].self, forKey: .fileStats) ?? []
        files = raw.enumerated().map { index, file in
            let stat = stats.indices.contains(index) ? stats[index] : nil
            return TorrentFile(
                index: index,
                name: file.name,
                length: file.length,
                bytesCompleted: file.bytesCompleted,
                wanted: stat?.wanted ?? true,
                priorityRaw: stat?.priority ?? 0
            )
        }
    }
}

/// Decoded `arguments` for a single-torrent files `torrent-get`.
struct TorrentFilesArguments: Decodable, Sendable {
    let torrents: [TorrentFilesEntry]
}

// MARK: - torrent-add

/// The torrent named in a `torrent-add` response (under `torrent-added` or
/// `torrent-duplicate`).
struct AddedTorrent: Decodable, Sendable {
    let id: Int?
    let name: String?
    let hashString: String?
}

/// Decoded `arguments` for `torrent-add`. Exactly one of these is present.
struct AddArguments: Decodable, Sendable {
    let added: AddedTorrent?
    let duplicate: AddedTorrent?

    enum CodingKeys: String, CodingKey {
        case added = "torrent-added"
        case duplicate = "torrent-duplicate"
    }
}

/// Outcome of an add request, surfaced to the UI.
struct AddOutcome: Sendable {
    let name: String
    let duplicate: Bool
}
