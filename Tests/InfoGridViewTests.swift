import AppKit
import XCTest

/// Tests for the torrent Info pane: the pure field list, the view's height
/// encapsulation (the regression that shipped a collapsed, overflowing grid),
/// the in-place vs. rebuild update path, and click-to-copy.
@MainActor
final class InfoGridViewTests: XCTestCase {

    // MARK: - Field list (pure)

    func testNameIsFirstFieldAndIsTruncatingNotFullWidth() {
        let fields = InfoGridView.fields(for: TorrentFactory.make())
        XCTAssertEqual(fields.first?.caption, "Name")
        // Name no longer claims a whole wrapping row — it truncates and is copyable.
        XCTAssertEqual(fields.first?.fullWidth, false)
        XCTAssertEqual(fields.first?.truncate, true)
        XCTAssertEqual(fields.first?.span, 2, "Name should span two columns")
        XCTAssertEqual(fields.last?.caption, "Hash")
    }

    func testCoreShortFieldsArePresentAndNotFullWidth() {
        let fields = InfoGridView.fields(for: TorrentFactory.make())
        let byCaption = Dictionary(uniqueKeysWithValues: fields.map { ($0.caption, $0) })
        for caption in ["Name", "Status", "Progress", "Ratio", "Size", "Downloaded",
                        "Uploaded", "Priority", "Queue", "Download ↓", "Upload ↑",
                        "ETA", "Peers", "Added", "Last activity"] {
            XCTAssertNotNil(byCaption[caption], "missing field \(caption)")
            XCTAssertEqual(byCaption[caption]?.fullWidth, false, "\(caption) should be a grid cell")
        }
    }

    func testCommentAndHashShareBottomRowTwoColumnsEach() {
        // With a comment: Comment + Hash are the last two fields, each two columns,
        // and Comment starts a fresh row so they sit together at the bottom.
        let withComment = InfoGridView.fields(for: TorrentFactory.make(["comment": "hi"]))
        let comment = withComment[withComment.count - 2]
        let hash = withComment[withComment.count - 1]
        XCTAssertEqual(comment.caption, "Comment")
        XCTAssertEqual(hash.caption, "Hash")
        XCTAssertEqual(comment.span, 2)
        XCTAssertEqual(hash.span, 2)
        XCTAssertFalse(comment.fullWidth)
        XCTAssertFalse(hash.fullWidth)
        XCTAssertTrue(comment.breakBefore, "Comment should start the bottom row")

        // Without a comment: Hash alone starts the bottom row, two columns wide.
        let noComment = InfoGridView.fields(for: TorrentFactory.make())
        let lastHash = noComment.last!
        XCTAssertEqual(lastHash.caption, "Hash")
        XCTAssertEqual(lastHash.span, 2)
        XCTAssertFalse(lastHash.fullWidth)
        XCTAssertTrue(lastHash.breakBefore, "Hash should start its own bottom row")
    }

    /// Name and Location share the top row: each two columns wide, Location right
    /// after Name, and neither full-width.
    func testNameAndLocationShareTopRowTwoColumnsEach() {
        let fields = InfoGridView.fields(for: TorrentFactory.make())
        XCTAssertEqual(fields[0].caption, "Name")
        XCTAssertEqual(fields[1].caption, "Location")
        for f in fields[0...1] {
            XCTAssertEqual(f.span, 2, "\(f.caption) should be two columns")
            XCTAssertFalse(f.fullWidth, "\(f.caption) should not be full width")
        }
        // Status/Progress drop below the name/location row.
        let captions = fields.map(\.caption)
        XCTAssertGreaterThan(captions.firstIndex(of: "Status")!, 1)
    }

    func testDownloadedIsCumulativeTotalWithoutEverWording() {
        let fields = InfoGridView.fields(for: TorrentFactory.make([
            "downloadedEver": 2_000_000_000, "leftUntilDone": 500, "sizeWhenDone": 1_000,
        ]))
        let downloaded = fields.first { $0.caption == "Downloaded" }!.value
        XCTAssertEqual(downloaded, Formatters.size(2_000_000_000))
        XCTAssertFalse(downloaded.contains("ever"))
    }

    func testSizeOmitsWantWhenAllFilesWanted() {
        let allWanted = InfoGridView.fields(for: TorrentFactory.make([
            "totalSize": 1_000, "sizeWhenDone": 1_000,
        ])).first { $0.caption == "Size" }!.value
        XCTAssertFalse(allWanted.contains("want"))

        let partial = InfoGridView.fields(for: TorrentFactory.make([
            "totalSize": 1_000, "sizeWhenDone": 600,
        ])).first { $0.caption == "Size" }!.value
        XCTAssertTrue(partial.contains("want"))
    }

    func testErrorFieldAppearsOnlyWhenErrored() {
        let clean = InfoGridView.fields(for: TorrentFactory.make())
        XCTAssertNil(clean.first { $0.caption == "Error" })

        let errored = InfoGridView.fields(for: TorrentFactory.make([
            "errorString": "tracker down", "error": 2,
        ]))
        let error = errored.first { $0.caption == "Error" }
        XCTAssertEqual(error?.value, "[2] tracker down")
        XCTAssertEqual(error?.fullWidth, true)
    }

    func testCommentAndCompletedAppearConditionally() {
        let base = InfoGridView.fields(for: TorrentFactory.make())
        XCTAssertNil(base.first { $0.caption == "Comment" })
        XCTAssertNil(base.first { $0.caption == "Completed" })

        let extra = InfoGridView.fields(for: TorrentFactory.make([
            "comment": "hello", "doneDate": 1_700_000_000,
        ]))
        XCTAssertEqual(extra.first { $0.caption == "Comment" }?.value, "hello")
        XCTAssertNotNil(extra.first { $0.caption == "Completed" })
    }

    func testZeroSpeedAndEtaRenderAsDash() {
        let fields = InfoGridView.fields(for: TorrentFactory.make([
            "rateDownload": 0, "rateUpload": 0,
            "status": TorrentStatus.seeding.rawValue, "percentDone": 1.0,
        ]))
        let byCaption = Dictionary(uniqueKeysWithValues: fields.map { ($0.caption, $0) })
        XCTAssertEqual(byCaption["Download ↓"]?.value, "—")
        XCTAssertEqual(byCaption["Upload ↑"]?.value, "—")
        XCTAssertEqual(byCaption["ETA"]?.value, "—")
    }

    func testValuesUseFormatters() {
        let fields = InfoGridView.fields(for: TorrentFactory.make([
            "percentDone": 0.5, "uploadRatio": 2.0,
        ]))
        let byCaption = Dictionary(uniqueKeysWithValues: fields.map { ($0.caption, $0) })
        XCTAssertEqual(byCaption["Progress"]?.value, Formatters.percent(0.5))
        XCTAssertEqual(byCaption["Ratio"]?.value, Formatters.ratio(2.0))
    }

    // MARK: - View encapsulation (the shipped regression)

    /// Lay the view out at a given detail-pane width. The view positions its cards
    /// manually in `layout()` and reports height via `intrinsicContentSize`, so we
    /// drive it with an explicit frame and a few settle passes (card width → value
    /// wrap width → row height → content height).
    private func laidOut(_ view: InfoGridView, width: CGFloat = 560) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        for _ in 0..<3 { view.needsLayout = true; view.layoutSubtreeIfNeeded() }
    }

    func testPopulatedViewHasContentDrivenHeight() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        view.update(with: TorrentFactory.make(), selectionCount: 1)
        laidOut(view)
        // Many rows of cards must produce a tall content height — the first bug
        // shipped a view that collapsed to ~0 and drew outside its bounds.
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 150)
        XCTAssertGreaterThan(view.renderedRowCount, 4)
    }

    func testChildrenStayWithinWidth() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        view.update(with: TorrentFactory.make(), selectionCount: 1)
        laidOut(view, width: 560)
        for sub in view.subviews {
            XCTAssertLessThanOrEqual(sub.frame.maxX, 560 + 1, "child overflows the view width")
        }
    }

    /// The view must reflow to a narrow width without imposing any minimum width —
    /// the regression where fixed grid columns locked the split divider so the
    /// sidebar could not be made smaller.
    func testReflowsToNarrowWidthWithoutMinimum() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        view.update(with: TorrentFactory.make(), selectionCount: 1)
        laidOut(view, width: 180)
        XCTAssertEqual(view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
                       "must not demand a fixed width")
        for sub in view.subviews {
            XCTAssertLessThanOrEqual(sub.frame.maxX, 180 + 1, "child overflows the narrow width")
        }
        // Narrower than the original means more wrapping, so the content is taller.
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 0)
    }

    func testPlaceholderRendersWithPositiveHeight() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        view.update(with: nil, selectionCount: 0)
        laidOut(view)
        XCTAssertEqual(view.placeholderText, "No torrent selected.")
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 0)

        view.update(with: nil, selectionCount: 3)
        XCTAssertEqual(view.placeholderText, "3 torrents selected.")
    }

    // MARK: - Update path: reuse vs. rebuild

    func testSameTorrentUpdatesValuesInPlace() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        view.update(with: TorrentFactory.make(["id": 7, "rateDownload": 0]), selectionCount: 1)
        laidOut(view)
        let rowsBefore = view.renderedRowCount
        let nameCard = view.renderedCard(forCaption: "Name")

        view.update(with: TorrentFactory.make(["id": 7, "rateDownload": 1_048_576]), selectionCount: 1)
        laidOut(view)
        XCTAssertEqual(view.renderedRowCount, rowsBefore, "structure unchanged → no rebuild")
        XCTAssertTrue(view.renderedCard(forCaption: "Name") === nameCard, "cards reused")
        XCTAssertEqual(view.renderedValue(forCaption: "Download ↓"), Formatters.speed(1_048_576))
    }

    func testStructureChangeRebuilds() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        view.update(with: TorrentFactory.make(["id": 7]), selectionCount: 1)
        laidOut(view)
        let rowsBefore = view.renderedRowCount
        XCTAssertNil(view.renderedValue(forCaption: "Comment"))

        view.update(with: TorrentFactory.make(["id": 7, "comment": "now present"]), selectionCount: 1)
        laidOut(view)
        XCTAssertGreaterThan(view.renderedRowCount, rowsBefore, "a full-width Comment row was added")
        XCTAssertEqual(view.renderedValue(forCaption: "Comment"), "now present")
    }

    func testSwitchingTorrentUpdatesValues() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        view.update(with: TorrentFactory.make(["id": 1, "name": "First"]), selectionCount: 1)
        view.update(with: TorrentFactory.make(["id": 2, "name": "Second"]), selectionCount: 1)
        XCTAssertEqual(view.renderedValue(forCaption: "Name"), "Second")
    }

    func testPlaceholderThenTorrentRenders() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        view.update(with: nil, selectionCount: 0)
        view.update(with: TorrentFactory.make(["name": "Back"]), selectionCount: 1)
        XCTAssertNil(view.placeholderText)
        XCTAssertEqual(view.renderedValue(forCaption: "Name"), "Back")
    }

    // MARK: - Click-to-copy

    private func click(_ field: NSView) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 2, y: 2), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        field.mouseDown(with: event)
    }

    func testClickingValueCopiesToPasteboardAndReportsValue() {
        let pb = NSPasteboard.general
        pb.clearContents()

        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        var copiedValue: String?
        view.onCopy = { copiedValue = $0 }
        view.update(with: TorrentFactory.make(["name": "Copy.Me.mkv"]), selectionCount: 1)

        let nameCard = try! XCTUnwrap(view.renderedCard(forCaption: "Name"))
        click(nameCard)

        // The toast reports the copied value ("Copied: Copy.Me.mkv"), not the caption.
        XCTAssertEqual(pb.string(forType: .string), "Copy.Me.mkv")
        XCTAssertEqual(copiedValue, "Copy.Me.mkv")
    }

    func testProgressValueIsReportedForToast() {
        let view = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        var copied: String?
        view.onCopy = { copied = $0 }
        view.update(with: TorrentFactory.make(["percentDone": 1.0]), selectionCount: 1)
        click(try! XCTUnwrap(view.renderedCard(forCaption: "Progress")))
        XCTAssertEqual(copied, Formatters.percent(1.0))
    }

    // MARK: - Adaptive columns

    func testUsesMoreColumnsWhenWiderSoFewerRows() {
        let wide = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        wide.update(with: TorrentFactory.make(), selectionCount: 1)
        laidOut(wide, width: 900)        // room for 4 columns

        let narrow = InfoGridView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        narrow.update(with: TorrentFactory.make(), selectionCount: 1)
        laidOut(narrow, width: 380)      // room for ~2 columns

        XCTAssertLessThan(wide.renderedRowCount, narrow.renderedRowCount,
                          "wider layout should pack more columns into fewer rows")
    }

    func testDashValueIsNotCopyable() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("UNCHANGED", forType: .string)

        let card = InfoCardView()
        var fired = false
        card.configure(caption: "ETA", value: "—", truncate: false) { _ in fired = true }
        click(card)

        XCTAssertEqual(pb.string(forType: .string), "UNCHANGED")
        XCTAssertFalse(fired)
    }

    func testClickingWholeCardCopiesFromCaptionAreaToo() {
        // The whole card is the click target, not just the value label.
        let card = InfoCardView()
        var copied: String?
        card.configure(caption: "Ratio", value: "2.15", truncate: false) { copied = $0 }
        click(card)
        XCTAssertEqual(copied, "2.15")
    }
}
