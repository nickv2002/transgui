import XCTest

final class ModelsTests: XCTestCase {
    func testStatusFallbackForUnknownRaw() {
        let t = TorrentFactory.make(["status": 99])
        XCTAssertEqual(t.status, .stopped)
    }

    func testIsTransferring() {
        XCTAssertTrue(TorrentFactory.make(["rateDownload": 1]).isTransferring)
        XCTAssertTrue(TorrentFactory.make(["rateUpload": 1]).isTransferring)
        XCTAssertFalse(TorrentFactory.make(["rateDownload": 0, "rateUpload": 0]).isTransferring)
    }

    func testHasError() {
        XCTAssertTrue(TorrentFactory.make(["errorString": "x"]).hasError)
        XCTAssertFalse(TorrentFactory.make(["errorString": ""]).hasError)
    }

    func testEtaDisplayDashWhenComplete() {
        let seeding = TorrentFactory.make([
            "status": TorrentStatus.seeding.rawValue, "percentDone": 1.0, "eta": -1])
        XCTAssertEqual(seeding.etaDisplay, "—")
    }

    func testEtaDisplayInfinityWhileDownloading() {
        let downloading = TorrentFactory.make([
            "status": TorrentStatus.downloading.rawValue, "percentDone": 0.2, "eta": -1])
        XCTAssertEqual(downloading.etaDisplay, "∞")
    }

    func testEtaDisplayDurationWhileDownloading() {
        let downloading = TorrentFactory.make([
            "status": TorrentStatus.downloading.rawValue, "percentDone": 0.2, "eta": 90])
        XCTAssertEqual(downloading.etaDisplay, "1m 30s")
    }

    func testNormalizeDownloadDir() {
        XCTAssertEqual(Torrent.normalizeDownloadDir("/data//movies/"), "/data/movies")
        XCTAssertEqual(Torrent.normalizeDownloadDir("/data/movies"), "/data/movies")
        XCTAssertEqual(Torrent.normalizeDownloadDir("/"), "/")
        XCTAssertEqual(Torrent.normalizeDownloadDir("/a///b///c/"), "/a/b/c")
    }

    func testTrackerHostStripsWww() {
        let t = TorrentFactory.make([
            "trackers": [["announce": "https://www.tracker.example.org:443/announce"]]])
        XCTAssertEqual(t.trackerHost, "tracker.example.org")
    }

    func testTrackerHostNilWhenNoTrackers() {
        XCTAssertNil(TorrentFactory.make(["trackers": []]).trackerHost)
    }

    func testBandwidthPriority() {
        XCTAssertEqual(TorrentFactory.make(["bandwidthPriority": -1]).bandwidthPriority, .low)
        XCTAssertEqual(TorrentFactory.make(["bandwidthPriority": 0]).bandwidthPriority, .normal)
        XCTAssertEqual(TorrentFactory.make(["bandwidthPriority": 1]).bandwidthPriority, .high)
        // Unknown raw → normal.
        XCTAssertEqual(TorrentFactory.make(["bandwidthPriority": 7]).bandwidthPriority, .normal)
    }

    func testSeedRatioDisplayAndSorting() {
        let global = TorrentFactory.make(["seedRatioMode": 0, "seedRatioLimit": 2.0])
        XCTAssertEqual(global.seedRatioDisplay, "Default")

        let single = TorrentFactory.make(["seedRatioMode": 1, "seedRatioLimit": 1.5])
        XCTAssertEqual(single.seedRatioDisplay, "1.50")
        XCTAssertEqual(single.effectiveRatioLimit, 1.5)

        let unlimited = TorrentFactory.make(["seedRatioMode": 2, "seedRatioLimit": 1.0])
        XCTAssertEqual(unlimited.seedRatioDisplay, "∞")
        XCTAssertEqual(unlimited.effectiveRatioLimit, .infinity)
    }

    func testTorrentListDecoding() {
        let json = """
        {"result":"success","arguments":{"torrents":[
          {"id":7,"name":"A","status":4,"percentDone":0.1,"totalSize":10,"sizeWhenDone":10,
           "leftUntilDone":9,"rateDownload":1,"rateUpload":2,"eta":100,"uploadRatio":0.0,
           "downloadDir":"/d","errorString":"","peersConnected":0,"peersSendingToUs":0,
           "peersGettingFromUs":0,"addedDate":0,"hashString":"h","queuePosition":0,
           "bandwidthPriority":0,"trackers":[],"comment":"","error":0,"doneDate":0,
           "activityDate":0,"downloadedEver":0,"uploadedEver":0,"seedRatioLimit":0.0,"seedRatioMode":0}
        ]}}
        """
        let resp = try! JSONDecoder().decode(
            RPCResponse<TorrentListArguments>.self, from: Data(json.utf8))
        XCTAssertEqual(resp.result, "success")
        XCTAssertEqual(resp.arguments?.torrents.count, 1)
        XCTAssertEqual(resp.arguments?.torrents.first?.id, 7)
        XCTAssertEqual(resp.arguments?.torrents.first?.name, "A")
    }

    /// A slim first-poll response omits the heavier fields; decoding must tolerate
    /// their absence with safe defaults (matching `firstFetchFields`).
    func testTorrentDecodesWithSlimFields() {
        // Only the fields in `firstFetchFields` are present (no trackers, comment,
        // peers, ever-totals, dates, or seed ratio).
        let json = """
        {"result":"success","arguments":{"torrents":[
          {"id":7,"name":"A","status":4,"percentDone":0.1,"totalSize":10,"sizeWhenDone":10,
           "leftUntilDone":9,"rateDownload":1,"rateUpload":2,"eta":100,"uploadRatio":0.0,
           "downloadDir":"/d","error":0,"errorString":"","addedDate":0,"hashString":"h",
           "queuePosition":0,"bandwidthPriority":0}
        ]}}
        """
        let resp = try! JSONDecoder().decode(
            RPCResponse<TorrentListArguments>.self, from: Data(json.utf8))
        let t = resp.arguments!.torrents.first!
        XCTAssertEqual(t.id, 7)
        XCTAssertEqual(t.name, "A")
        // Omitted fields default rather than failing to decode.
        XCTAssertEqual(t.trackers, [])
        XCTAssertEqual(t.comment, "")
        XCTAssertNil(t.trackerHost)
        XCTAssertEqual(t.peersConnected, 0)
        XCTAssertEqual(t.downloadedEver, 0)
        XCTAssertEqual(t.uploadedEver, 0)
        XCTAssertEqual(t.seedRatioMode, .global)
    }

    /// `firstFetchFields` must be a subset of the full set and must exclude the
    /// heavy fields it exists to drop.
    func testFirstFetchFieldsDropsHeavyFields() {
        let slim = Set(Torrent.firstFetchFields)
        let full = Set(Torrent.requestedFields)
        XCTAssertTrue(slim.isSubset(of: full))
        XCTAssertFalse(slim.contains("trackers"))
        XCTAssertFalse(slim.contains("comment"))
        XCTAssertLessThan(slim.count, full.count)
    }

    func testFilesEntryMergesFilesAndStats() {
        let json = """
        {"id":1,"files":[
          {"name":"a.mkv","length":100,"bytesCompleted":50},
          {"name":"b.nfo","length":10,"bytesCompleted":10}],
         "fileStats":[
          {"wanted":true,"priority":1},
          {"wanted":false,"priority":-1}]}
        """
        let entry = try! JSONDecoder().decode(TorrentFilesEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.files.count, 2)
        XCTAssertEqual(entry.files[0].name, "a.mkv")
        XCTAssertEqual(entry.files[0].percentDone, 0.5)
        XCTAssertEqual(entry.files[0].priority, .high)
        XCTAssertTrue(entry.files[0].wanted)
        XCTAssertEqual(entry.files[1].priority, .low)
        XCTAssertFalse(entry.files[1].wanted)
    }

    func testFilesEntryDefaultsWhenStatsMissing() {
        let json = """
        {"id":1,"files":[{"name":"a","length":0,"bytesCompleted":0}]}
        """
        let entry = try! JSONDecoder().decode(TorrentFilesEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.files.count, 1)
        XCTAssertTrue(entry.files[0].wanted)        // defaults to wanted
        XCTAssertEqual(entry.files[0].priority, .normal)
        XCTAssertEqual(entry.files[0].percentDone, 1) // zero-length file is "done"
    }
}
