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
    }

    var status: TorrentStatus { TorrentStatus(rawValue: statusRaw) ?? .stopped }

    /// The list of fields the MVP requests from `torrent-get`.
    static let requestedFields = [
        "id", "name", "status", "percentDone", "totalSize", "sizeWhenDone",
        "leftUntilDone", "rateDownload", "rateUpload", "eta", "uploadRatio",
        "downloadDir", "errorString", "peersConnected", "peersSendingToUs",
        "peersGettingFromUs", "addedDate", "hashString",
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
