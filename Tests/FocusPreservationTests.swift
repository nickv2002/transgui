import AppKit
import XCTest

/// Tests that verify which AppKit reload operations steal focus from
/// a focused NSTableView — reproducing the files-table focus-loss bug.
///
/// Each test isolates one operation from applyTorrents() to identify
/// the exact culprit.
@MainActor
final class FocusPreservationTests: XCTestCase {

    // MARK: - Helpers

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.makeKeyAndOrderFront(nil)
        return w
    }

    private func makeTable(in window: NSWindow, frame: NSRect) -> NSTableView {
        let table = NSTableView(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("col")))
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = table
        window.contentView!.addSubview(scroll)
        return table
    }

    private func focusAndAssert(_ table: NSTableView, in window: NSWindow,
                                 file: StaticString = #file, line: UInt = #line) {
        let ok = window.makeFirstResponder(table)
        XCTAssertTrue(ok, "table should accept first responder", file: file, line: line)
        XCTAssertIdentical(window.firstResponder, table,
                           "table should be first responder", file: file, line: line)
    }

    private func assertStillFocused(_ table: NSTableView, in window: NSWindow,
                                     after label: String,
                                     file: StaticString = #file, line: UInt = #line) {
        XCTAssertIdentical(window.firstResponder, table,
                           "files table should still be focused after: \(label)",
                           file: file, line: line)
    }

    // MARK: - Individual operations

    func testMainTableReloadDataDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let mainTable  = makeTable(in: window, frame: NSRect(x: 0, y: 200, width: 600, height: 200))
        focusAndAssert(filesTable, in: window)

        mainTable.reloadData()

        assertStillFocused(filesTable, in: window, after: "mainTable.reloadData()")
        window.orderOut(nil)
    }

    func testFilesTableReloadDataDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: window.contentView!.bounds)
        focusAndAssert(filesTable, in: window)

        filesTable.reloadData()

        assertStillFocused(filesTable, in: window, after: "filesTable.reloadData()")
        window.orderOut(nil)
    }

    func testOutlineViewReloadDataDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 400))

        let outline = NSOutlineView(frame: .zero)
        outline.addTableColumn(NSTableColumn(identifier: .init("col")))
        let sidebarScroll = NSScrollView(frame: NSRect(x: 400, y: 0, width: 200, height: 400))
        sidebarScroll.documentView = outline
        window.contentView!.addSubview(sidebarScroll)

        focusAndAssert(filesTable, in: window)

        outline.reloadData()

        assertStillFocused(filesTable, in: window, after: "outlineView.reloadData()")
        window.orderOut(nil)
    }

    func testOutlineViewSelectRowDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 400))

        let outline = NSOutlineView(frame: .zero)
        outline.addTableColumn(NSTableColumn(identifier: .init("col")))
        let sidebarScroll = NSScrollView(frame: NSRect(x: 400, y: 0, width: 200, height: 400))
        sidebarScroll.documentView = outline
        window.contentView!.addSubview(sidebarScroll)

        focusAndAssert(filesTable, in: window)

        // reselectActive() in SidebarController calls this
        outline.selectRowIndexes([], byExtendingSelection: false)

        assertStillFocused(filesTable, in: window, after: "outlineView.selectRowIndexes()")
        window.orderOut(nil)
    }

    func testMainTableSelectRowIndexesDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let mainTable  = makeTable(in: window, frame: NSRect(x: 0, y: 200, width: 600, height: 200))
        focusAndAssert(filesTable, in: window)

        // restoreSelection() calls this
        mainTable.selectRowIndexes([], byExtendingSelection: false)

        assertStillFocused(filesTable, in: window, after: "mainTable.selectRowIndexes()")
        window.orderOut(nil)
    }

    /// Simulates the onFetchingChanged(false) call that fires via defer AFTER
    /// applyTorrents returns — this is the prime suspect for post-restore theft.
    func testProgressIndicatorStopAndDotShowDoNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(spinner)

        let dot = NSImageView()
        dot.isHidden = true
        window.contentView!.addSubview(dot)

        spinner.startAnimation(nil)
        focusAndAssert(filesTable, in: window)

        // Simulate makeFirstResponder at end of applyTorrents, then onFetchingChanged(false)
        window.makeFirstResponder(filesTable)
        spinner.stopAnimation(nil)
        dot.isHidden = false

        assertStillFocused(filesTable, in: window,
                           after: "stopAnimation + dot.isHidden = false (onFetchingChanged)")
        window.orderOut(nil)
    }

    /// Verifies that a DispatchQueue.main.async restoration survives onFetchingChanged.
    func testDeferredMakeFirstResponderSurvivesPostApplyWork() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        window.contentView!.addSubview(spinner)
        let dot = NSImageView()
        dot.isHidden = true
        window.contentView!.addSubview(dot)

        spinner.startAnimation(nil)
        focusAndAssert(filesTable, in: window)

        // Simulate: applyTorrents queues deferred restore, then onFetchingChanged fires
        let expectation = expectation(description: "deferred makeFirstResponder")
        DispatchQueue.main.async {
            window.makeFirstResponder(filesTable)
            expectation.fulfill()
        }
        // onFetchingChanged fires (in same run-loop cycle as applyTorrents returning)
        spinner.stopAnimation(nil)
        dot.isHidden = false

        waitForExpectations(timeout: 1)
        assertStillFocused(filesTable, in: window,
                           after: "deferred makeFirstResponder after onFetchingChanged")
        window.orderOut(nil)
    }

    /// Full sequence matching applyTorrents() to catch combined effects.
    func testFullRefreshSequenceDoesNotStealFocus() {
        let window = makeWindow()
        let filesTable = makeTable(in: window, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let mainTable  = makeTable(in: window, frame: NSRect(x: 0, y: 300, width: 400, height: 100))

        let outline = NSOutlineView(frame: .zero)
        outline.addTableColumn(NSTableColumn(identifier: .init("col")))
        let sidebarScroll = NSScrollView(frame: NSRect(x: 400, y: 0, width: 200, height: 400))
        sidebarScroll.documentView = outline
        window.contentView!.addSubview(sidebarScroll)

        focusAndAssert(filesTable, in: window)

        // Replay applyTorrents() operations in order:
        outline.reloadData()                                     // sidebar.update()
        mainTable.reloadData()                                   // tableView.reloadData()
        mainTable.selectRowIndexes([], byExtendingSelection: false) // restoreSelection()
        filesTable.reloadData()                                  // reloadFilesData()

        assertStillFocused(filesTable, in: window, after: "full applyTorrents sequence")
        window.orderOut(nil)
    }
}

/// Reproduces the *selection* loss (not just focus) on the files table, using a
/// real data source so the table actually has rows to select.
@MainActor
final class FilesSelectionPreservationTests: XCTestCase, NSTableViewDataSource, NSTableViewDelegate {
    var rowCount = 5

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "row \(row)")
    }

    private func makeSetup() -> (NSWindow, NSTableView) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.makeKeyAndOrderFront(nil)
        let table = NSTableView(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.documentView = table
        w.contentView!.addSubview(scroll)
        table.reloadData()
        return (w, table)
    }

    /// Documents the root cause: a bare `reloadData()` drops the selection on this
    /// toolchain even when the row count is unchanged. This is why both the main and
    /// files tables must restore selection after reloading.
    func testBareReloadDataDropsSelection() {
        let (w, table) = makeSetup()
        w.makeFirstResponder(table)
        table.selectRowIndexes([2], byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 2, "precondition")

        table.reloadData()  // poll re-fetch, same count
        XCTAssertEqual(table.selectedRow, -1, "bare reloadData is expected to drop selection")
        w.orderOut(nil)
    }

    /// Verifies the preserve/restore pattern that `reloadFilesData()` applies:
    /// capture selected row indexes, reload, reselect the still-valid ones.
    private func reloadPreservingSelection(_ table: NSTableView) {
        let selection = table.selectedRowIndexes
        table.reloadData()
        let valid = selection.filteredIndexSet { $0 < rowCount }
        if !valid.isEmpty { table.selectRowIndexes(valid, byExtendingSelection: false) }
    }

    func testReloadPreservingSelectionKeepsSelection() {
        let (w, table) = makeSetup()
        w.makeFirstResponder(table)
        table.selectRowIndexes([2], byExtendingSelection: false)

        reloadPreservingSelection(table)  // poll re-fetch, same count
        XCTAssertEqual(table.selectedRow, 2, "selection lost after preserving reload")
        w.orderOut(nil)
    }

    func testReloadPreservingSelectionSurvivesFocusBounce() {
        let (w, table) = makeSetup()
        w.makeFirstResponder(table)
        table.selectRowIndexes([2], byExtendingSelection: false)

        // applyTorrents bounces first responder around the main table reload
        w.makeFirstResponder(nil)
        reloadPreservingSelection(table)
        w.makeFirstResponder(table)
        XCTAssertEqual(table.selectedRow, 2, "selection lost after focus bounce")
        XCTAssertIdentical(w.firstResponder, table, "focus lost after focus bounce")
        w.orderOut(nil)
    }

    func testReloadPreservingSelectionDropsRowsBeyondNewCount() {
        let (w, table) = makeSetup()
        w.makeFirstResponder(table)
        table.selectRowIndexes([4], byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 4)

        rowCount = 3   // files list shrank
        reloadPreservingSelection(table)
        XCTAssertEqual(table.selectedRow, -1, "selection beyond new count should be dropped")
        w.orderOut(nil)
    }

    func testReloadDataWithFewerRowsDropsSelection() {
        let (w, table) = makeSetup()
        w.makeFirstResponder(table)
        table.selectRowIndexes([4], byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 4)

        rowCount = 3   // files list shrank
        table.reloadData()
        XCTAssertEqual(table.selectedRow, -1, "selection beyond new count should be dropped")
        w.orderOut(nil)
    }
}
