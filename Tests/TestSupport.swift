import Foundation

/// Builds a `Torrent` for tests by decoding a default JSON object with overrides.
/// The base dictionary supplies every key (so the factory is unaffected by
/// `Torrent`'s tolerant `decodeIfPresent` decoding); pass `overrides` to change
/// specific ones.
enum TorrentFactory {
    static func make(_ overrides: [String: Any] = [:]) -> Torrent {
        var dict: [String: Any] = [
            "id": 1,
            "name": "Example Torrent",
            "status": TorrentStatus.downloading.rawValue,
            "percentDone": 0.5,
            "totalSize": 1_000,
            "sizeWhenDone": 1_000,
            "leftUntilDone": 500,
            "rateDownload": 0,
            "rateUpload": 0,
            "eta": -1,
            "uploadRatio": 0.0,
            "downloadDir": "/downloads",
            "errorString": "",
            "peersConnected": 0,
            "peersSendingToUs": 0,
            "peersGettingFromUs": 0,
            "addedDate": 0,
            "hashString": "abc123",
            "queuePosition": 0,
            "bandwidthPriority": 0,
            "trackers": [] as [[String: Any]],
            "comment": "",
            "error": 0,
            "doneDate": 0,
            "activityDate": 0,
            "downloadedEver": 0,
            "uploadedEver": 0,
            "seedRatioLimit": 0.0,
            "seedRatioMode": 0,
        ]
        for (k, v) in overrides { dict[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Torrent.self, from: data)
    }
}
