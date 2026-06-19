import XCTest
import AppKit

final class FilteringTests: XCTestCase {
    func testAllMatchesEverything() {
        XCTAssertTrue(StatusFilter.all.matches(TorrentFactory.make()))
    }

    func testDownloading() {
        let t = TorrentFactory.make(["status": TorrentStatus.downloading.rawValue])
        XCTAssertTrue(StatusFilter.downloading.matches(t))
        let stopped = TorrentFactory.make(["status": TorrentStatus.stopped.rawValue])
        XCTAssertFalse(StatusFilter.downloading.matches(stopped))
    }

    func testCompletedByPercentOrSeeding() {
        XCTAssertTrue(StatusFilter.completed.matches(TorrentFactory.make(["percentDone": 1.0])))
        XCTAssertTrue(StatusFilter.completed.matches(
            TorrentFactory.make(["status": TorrentStatus.seeding.rawValue, "percentDone": 1.0])))
        XCTAssertFalse(StatusFilter.completed.matches(TorrentFactory.make(["percentDone": 0.3])))
    }

    func testActiveRequiresTransfer() {
        let active = TorrentFactory.make([
            "status": TorrentStatus.downloading.rawValue, "rateDownload": 500])
        XCTAssertTrue(StatusFilter.active.matches(active))
        // Running but idle (no throughput) is not "active".
        let idle = TorrentFactory.make([
            "status": TorrentStatus.downloading.rawValue, "rateDownload": 0, "rateUpload": 0])
        XCTAssertFalse(StatusFilter.active.matches(idle))
        // Stopped is never active.
        let stopped = TorrentFactory.make([
            "status": TorrentStatus.stopped.rawValue, "rateDownload": 500])
        XCTAssertFalse(StatusFilter.active.matches(stopped))
    }

    func testInactive() {
        // Running, no throughput, incomplete → inactive.
        let idle = TorrentFactory.make([
            "status": TorrentStatus.downloading.rawValue,
            "rateDownload": 0, "rateUpload": 0, "percentDone": 0.4])
        XCTAssertTrue(StatusFilter.inactive.matches(idle))
        // Stopped is excluded from inactive.
        let stopped = TorrentFactory.make(["status": TorrentStatus.stopped.rawValue])
        XCTAssertFalse(StatusFilter.inactive.matches(stopped))
    }

    func testStopped() {
        XCTAssertTrue(StatusFilter.stopped.matches(
            TorrentFactory.make(["status": TorrentStatus.stopped.rawValue])))
    }

    func testError() {
        XCTAssertTrue(StatusFilter.error.matches(TorrentFactory.make(["errorString": "tracker down"])))
        XCTAssertFalse(StatusFilter.error.matches(TorrentFactory.make(["errorString": ""])))
    }

    func testWaiting() {
        for status: TorrentStatus in [.checkWait, .checking, .downloadWait, .seedWait] {
            XCTAssertTrue(StatusFilter.waiting.matches(
                TorrentFactory.make(["status": status.rawValue])), "expected waiting for \(status)")
        }
        XCTAssertFalse(StatusFilter.waiting.matches(
            TorrentFactory.make(["status": TorrentStatus.downloading.rawValue])))
    }

    func testStatusColors() {
        // Tints documented in 07-resize-tints-window-frame.md.
        XCTAssertEqual(StatusFilter.active.color, .systemPurple)
        XCTAssertEqual(StatusFilter.stopped.color, .systemYellow)
        XCTAssertEqual(StatusFilter.completed.color, .systemGreen)
        XCTAssertEqual(StatusFilter.inactive.color, .systemGray)
    }

    func testAllFiltersHaveSymbols() {
        for f in StatusFilter.allCases {
            XCTAssertFalse(f.symbol.isEmpty)
            XCTAssertFalse(f.displayName.isEmpty)
        }
    }

    func testSidebarTrackerFilter() {
        let t = TorrentFactory.make([
            "trackers": [["announce": "https://tracker.example.org/announce"]]])
        XCTAssertTrue(SidebarFilter.tracker("tracker.example.org").matches(t))
        XCTAssertFalse(SidebarFilter.tracker("other.org").matches(t))
    }

    func testSidebarFolderFilterNormalizes() {
        let t = TorrentFactory.make(["downloadDir": "/data/movies"])
        XCTAssertTrue(SidebarFilter.folder("/data//movies/").matches(t))
        XCTAssertFalse(SidebarFilter.folder("/data/tv").matches(t))
    }

    func testSidebarAllIsStatusAll() {
        XCTAssertEqual(SidebarFilter.all, .status(.all))
    }
}
