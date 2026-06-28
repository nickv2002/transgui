import AppKit

/// Top-level window: a torrent table, a detail pane, a toolbar of actions, and a
/// status bar. Owns the `RefreshController` that drives live updates.
final class MainWindowController: NSWindowController {
    let refresh: RefreshController

    let tableView = TorrentTableView()
    private let infoGrid = InfoGridView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Bottom-left fetch indicator: an animated spinner while a poll is in flight,
    /// a static dot (tinted by connection state) when idle.
    private let fetchSpinner = NSProgressIndicator()
    private let idleDot = NSImageView()

    /// The toast currently on screen, if any, so a new toast can replace it at once.
    private weak var activeToast: ToastView?

    /// Detail-pane tabs (Info / Files) and the per-file table.
    let detailTabView = NSTabView()
    let filesTable = FilesTableView()

    /// Source-list sidebar of status / tracker / folder filter groups.
    let sidebar = SidebarController()
    /// The active sidebar filter applied before the search filter.
    private var activeFilter: SidebarFilter = .all

    /// Files currently shown in the Files tab, and which torrent they belong to.
    var files: [TorrentFile] = []
    var filesTorrentId: Int?
    /// In-flight files fetch, so a new selection can cancel a stale one.
    var filesFetchTask: Task<Void, Never>?

    /// Full sorted model — every torrent from the server.
    var torrents: [Torrent] = []

    /// Width thresholds (pt) for the Added column's three date forms, measured once
    /// from representative strings so each form appears right as it starts to fit:
    /// below `mid` → numeric date; `mid`..<`full` → numeric date+time; ≥`full` →
    /// full date+time.
    private lazy var addedWidthThresholds: (mid: CGFloat, full: CGFloat) = {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width + 16 }
        return (mid: width(Formatters.compactDateTime(epoch)), full: width(Formatters.date(epoch)))
    }()

    /// What the table actually renders: `torrents` after applying `filterText`.
    /// Keeping this derived list lets the search filter the view without touching
    /// the model, the refresh loop, or the sort.
    private var displayed: [Torrent] = []

    /// Current search text; empty means "show everything".
    private var filterText = ""

    /// How the search box matches: fuzzy subsequence (ranked) or exact substring.
    enum SearchMode: Int { case fuzzy, exact }

    /// UserDefaults key persisting the chosen match mode across launches.
    private static let searchModeDefaultsKey = "SearchMode"

    /// Restored from UserDefaults so the choice survives relaunch; when the key
    /// has never been written the mode defaults to `.exact`.
    private(set) var searchMode: SearchMode = {
        guard let raw = UserDefaults.standard.object(forKey: searchModeDefaultsKey) as? Int,
              let mode = SearchMode(rawValue: raw) else { return .exact }
        return mode
    }()

    /// Switch match mode (from the search field's magnifying-glass menu) and re-filter.
    func setSearchMode(_ mode: SearchMode) {
        guard mode != searchMode else { return }
        searchMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.searchModeDefaultsKey)
        let ids = selectedTorrentIds()
        rebuildDisplayed()
        tableView.reloadData()
        restoreSelection(ids)
        updateDetail()
        updateStatusBar(state: refresh.state)
        updateSearchPlaceholder()
        window?.toolbar?.validateVisibleItems()
    }

    /// Reflect the active match mode in the search field's placeholder text.
    func updateSearchPlaceholder() {
        searchField?.placeholderString = searchMode == .fuzzy
            ? "Fuzzy filter by name"
            : "Exact filter by name"
    }

    /// The placeholder string for the current search mode (used when the search
    /// toolbar item is first created).
    var searchPlaceholder: String {
        searchMode == .fuzzy ? "Fuzzy filter by name" : "Exact filter by name"
    }

    /// The toolbar's search field, retained so ⌘F can focus it.
    weak var searchField: NSSearchField?

    /// Make the toolbar search field first responder (wired to the ⌘F Find menu).
    func focusSearch() {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
    }

    // Column identifiers double as sort keys.
    private enum Column: String, CaseIterable {
        case queue, name, size, status, progress, down, up, eta, ratio, ratioLimit, added, tracker

        var title: String {
            switch self {
            case .queue: return "#"
            case .name: return "Name"
            case .size: return "Size"
            case .status: return "Status"
            case .progress: return "Progress"
            case .down: return "↓ Speed"
            case .up: return "↑ Speed"
            case .eta: return "ETA"
            case .ratio: return "Ratio"
            case .ratioLimit: return "Ratio Limit"
            case .added: return "Added"
            case .tracker: return "Tracker"
            }
        }

        var width: CGFloat {
            switch self {
            case .queue: return 40
            case .name: return 260
            case .size: return 80
            case .status: return 110
            case .progress: return 90
            case .down, .up: return 80
            case .eta: return 70
            case .ratio: return 60
            case .ratioLimit: return 80
            case .added: return 130
            case .tracker: return 150
            }
        }

        /// Columns hidden by default (still toggleable from the header menu).
        var hiddenByDefault: Bool {
            switch self {
            case .size, .ratioLimit, .added, .tracker: return true
            default: return false
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    // MARK: - Init

    init(config: AppConfig) {
        self.refresh = RefreshController(config: config)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transmission Remote"
        // Restore the saved frame if one exists; otherwise center on first launch.
        // The frame is also saved explicitly on terminate (see AppDelegate) —
        // relying on setFrameAutosaveName alone is unreliable under this app's
        // manual `main.swift` run loop, so changes weren't persisting.
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        super.init(window: window)

        buildToolbar()
        buildLayout()
        wireRefresh()
        observeWindow()
        updateWindowTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refresh.start()
    }

    /// Apply a freshly reloaded config without rebuilding the window.
    func applyConfig(_ config: AppConfig) {
        refresh.updateConfig(config)
        updateWindowTitle()
    }

    /// Switch to a different server (from the Server menu). Clears the list to a
    /// "Connecting…" state; the existing connecting flow repaints once connected.
    func selectServer(_ name: String) {
        guard name != refresh.currentServerName else { return }
        refresh.selectServer(named: name)
        torrents = []
        rebuildDisplayed()
        tableView.reloadData()
        updateDetail()
        updateStatusBar(state: refresh.state)
        updateWindowTitle()
    }

    /// Reflect the active server in the window title when more than one is configured.
    func updateWindowTitle() {
        if refresh.availableServerNames.count > 1 {
            window?.title = "Transmission Remote — \(refresh.currentServerName)"
        } else {
            window?.title = "Transmission Remote"
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }

        // Table inside a scroll view.
        configureColumns()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClickRow)
        tableView.menu = rowContextMenu()
        tableView.onReturnKey = { [weak self] in
            guard let self, self.selectedTorrents.count == 1 else { return }
            self.renameSelected(nil)
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        // Detail pane.
        infoGrid.onCopy = { [weak self] value in self?.showToast("Copied: \(value)") }
        infoGrid.update(with: [])
        let detailScroll = NSScrollView()
        let detailContainer = NSView()
        detailContainer.addSubview(infoGrid)
        infoGrid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoGrid.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 10),
            infoGrid.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -10),
            infoGrid.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 8),
            // Pin the bottom too so the scroll content fits the grid exactly (no
            // trailing blank space).
            infoGrid.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -8),
        ])
        detailScroll.documentView = detailContainer
        detailScroll.hasVerticalScroller = true
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailContainer.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])

        // Detail tabs: Info (the text above) + Files (per-file table).
        let filesScroll = buildFilesTable()
        detailTabView.delegate = self
        let infoTab = NSTabViewItem(identifier: "info")
        infoTab.label = "Info"
        infoTab.view = detailScroll
        let filesTab = NSTabViewItem(identifier: "files")
        filesTab.label = "Files"
        filesTab.view = filesScroll
        detailTabView.addTabViewItem(infoTab)
        detailTabView.addTabViewItem(filesTab)

        // Vertical split between table and detail.
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailTabView)
        split.translatesAutoresizingMaskIntoConstraints = false
        split.autosaveName = "DetailSplit"

        // Sidebar filter groups, then the table/detail split, side by side.
        sidebar.onFilterChange = { [weak self] filter in self?.applyFilter(filter) }
        let mainSplit = NSSplitView()
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(sidebar.scrollView)
        mainSplit.addArrangedSubview(split)
        mainSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.autosaveName = "MainSplit"
        sidebar.scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        // Status bar.
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Connecting…"

        // Fetch indicator (spinner) + idle dot, occupying the same far-left slot.
        fetchSpinner.style = .spinning
        fetchSpinner.controlSize = .small
        fetchSpinner.isDisplayedWhenStopped = false
        fetchSpinner.translatesAutoresizingMaskIntoConstraints = false
        idleDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Idle")
        idleDot.contentTintColor = .systemGray
        idleDot.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        idleDot.translatesAutoresizingMaskIntoConstraints = false
        idleDot.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dotClicked(_:))))

        let statusBar = NSView()
        statusBar.addSubview(fetchSpinner)
        statusBar.addSubview(idleDot)
        statusBar.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fetchSpinner.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            fetchSpinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            fetchSpinner.widthAnchor.constraint(equalToConstant: 12),
            fetchSpinner.heightAnchor.constraint(equalToConstant: 12),
            idleDot.centerXAnchor.constraint(equalTo: fetchSpinner.centerXAnchor),
            idleDot.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            idleDot.widthAnchor.constraint(equalToConstant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: fetchSpinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Explicit constraints: split fills the window above a fixed-height status
        // bar. (An NSStackView here collapsed the split — and the table inside it —
        // to zero height because the split view has no intrinsic content size.)
        let content = DropView()
        content.onDropFiles = { [weak self] urls in self?.addFiles(urls) }
        content.onDropText = { [weak self] text in self?.addDroppedText(text) }
        content.addSubview(mainSplit)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        // Give the detail pane and sidebar sensible starting sizes once laid out —
        // but only when there's no autosaved divider position to restore.
        DispatchQueue.main.async {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "NSSplitView Subview Frames DetailSplit") == nil {
                let h = split.bounds.height
                if h > 200 { split.setPosition(h - 170, ofDividerAt: 0) }
            }
            if defaults.object(forKey: "NSSplitView Subview Frames MainSplit") == nil {
                mainSplit.setPosition(190, ofDividerAt: 0)
            }
        }
    }

    private func configureColumns() {
        for column in Column.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            col.minWidth = 36
            col.isHidden = column.hiddenByDefault
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(col)
        }
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        // Finder-like: dragging a column wider grows the total content width and
        // scrolls horizontally rather than shrinking the other columns. Columns
        // keep their exact widths; leftover window width shows as empty space.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Persist column order / width / visibility across launches.
        tableView.autosaveName = "TorrentTable"
        tableView.autosaveTableColumns = true
        tableView.headerView?.menu = columnHeaderMenu()

        // Restore the saved sort order, if any.
        if let key = UserDefaults.standard.string(forKey: "TorrentSortKey") {
            let ascending = UserDefaults.standard.bool(forKey: "TorrentSortAscending")
            tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        }
    }

    /// Right-click header menu to show/hide columns and auto-size widths.
    private func columnHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for column in Column.allCases where column != .name {
            let item = menu.addItem(withTitle: column.title.isEmpty ? column.rawValue : column.title,
                                    action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.representedObject = column.rawValue
            item.target = self
        }
        menu.addItem(.separator())
        let fit = menu.addItem(withTitle: "Auto-Size Columns", action: #selector(autoSizeColumns(_:)), keyEquivalent: "")
        fit.target = self
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == key }) else { return }
        col.isHidden.toggle()
    }

    /// Refresh the header menu checkmarks to reflect current column visibility.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let key = item.representedObject as? String,
                  let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == key }) else { continue }
            item.state = col.isHidden ? .off : .on
        }
    }

    /// Size each visible column to fit its header and the widest displayed value.
    @objc private func autoSizeColumns(_ sender: Any?) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for col in tableView.tableColumns where !col.isHidden {
            guard let column = Column(rawValue: col.identifier.rawValue) else { continue }
            if column == .progress { continue }   // fixed-style bar cell
            var maxWidth = (col.title as NSString).size(withAttributes: attrs).width + 16
            for t in displayed {
                let text = cellText(for: column, torrent: t)
                let w = (text as NSString).size(withAttributes: attrs).width + 16
                if w > maxWidth { maxWidth = w }
            }
            col.width = min(max(maxWidth, col.minWidth), 600)
        }
    }

    // MARK: - Refresh wiring

    private func wireRefresh() {
        refresh.onTorrents = { [weak self] torrents in
            self?.applyTorrents(torrents)
        }
        refresh.onState = { [weak self] state in
            self?.updateStatusBar(state: state)
        }
        refresh.onFetchingChanged = { [weak self] fetching in
            guard let self else { return }
            if fetching {
                self.idleDot.isHidden = true
                self.fetchSpinner.startAnimation(nil)
            } else {
                self.fetchSpinner.stopAnimation(nil)
                self.idleDot.isHidden = false
            }
        }
    }

    /// Dot color reflecting the connection state (a free connection cue when idle).
    private func connectionDotColor(for state: RefreshController.State) -> NSColor {
        switch state {
        case .connected: return .systemGreen
        case .failed: return .systemRed
        case .idle, .connecting: return .systemGray
        }
    }

    @objc private func dotClicked(_ sender: Any?) {
        refresh.refreshNow()
    }

    private func applyTorrents(_ incoming: [Torrent]) {
        // Preserve the user's selection across reloads by id.
        let selectedIds = selectedTorrentIds()
        // sidebar/table reloads can steal focus; save it so the files table
        // stays focused across polls when the user is working there.
        let filesTableFocused = window?.firstResponder === filesTable
        torrents = incoming
        sortTorrents()
        sidebar.update(with: torrents)
        rebuildDisplayed()
        tableView.reloadData()
        restoreSelection(selectedIds)
        updateDetail()
        loadFilesIfNeeded()
        updateStatusBar(state: refresh.state)
        window?.toolbar?.validateVisibleItems()
        if filesTableFocused { window?.makeFirstResponder(filesTable) }
    }

    /// Recompute the rendered list from `torrents` + `filterText` + `searchMode`.
    ///
    /// Empty filter: show everything in the current column-sort order. `.exact`:
    /// case-insensitive substring filter, keeping the column-sort order. `.fuzzy`:
    /// subsequence matching (see `FuzzyMatch`), ranked by match quality so the
    /// closest matches float to the top (e.g. `ppgrl` finds "papergirls").
    private func rebuildDisplayed() {
        // Sidebar filter first, then the search box.
        let base = activeFilter == .all ? torrents : torrents.filter { activeFilter.matches($0) }
        guard !filterText.isEmpty else {
            displayed = base
            return
        }
        switch searchMode {
        case .exact:
            displayed = base.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        case .fuzzy:
            displayed = base
                .compactMap { t -> (Torrent, Int)? in
                    FuzzyMatch.score(query: filterText, candidate: t.name).map { (t, $0) }
                }
                .sorted { a, b in
                    a.1 != b.1
                        ? a.1 > b.1
                        : a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
                }
                .map(\.0)
        }
    }

    private func restoreSelection(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        let rows = IndexSet(displayed.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { $0.offset })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Apply a sidebar filter selection and re-render the list.
    private func applyFilter(_ filter: SidebarFilter) {
        guard filter != activeFilter else { return }
        activeFilter = filter
        let ids = selectedTorrentIds()
        rebuildDisplayed()
        tableView.reloadData()
        restoreSelection(ids)
        updateDetail()
        loadFilesIfNeeded()
        updateStatusBar(state: refresh.state)
    }

    /// Live filtering as the user types in the toolbar search field.
    @objc func searchChanged(_ sender: NSSearchField) {
        let selectedIds = selectedTorrentIds()
        filterText = sender.stringValue
        rebuildDisplayed()
        tableView.reloadData()
        restoreSelection(selectedIds)
        updateDetail()
        updateStatusBar(state: refresh.state)
        window?.toolbar?.validateVisibleItems()
    }

    private func updateStatusBar(state: RefreshController.State) {
        idleDot.contentTintColor = connectionDotColor(for: state)
        let connection: String
        switch state {
        case .idle: connection = "Connecting…"
        case .connecting: connection = "Connecting…"
        case .connected(let version): connection = "Connected — Transmission \(version)"
        case .failed(let message): connection = "⚠︎ \(message)"
        }

        let totalDown = torrents.reduce(Int64(0)) { $0 + $1.rateDownload }
        let totalUp = torrents.reduce(Int64(0)) { $0 + $1.rateUpload }
        let down = Formatters.speed(totalDown)
        let up = Formatters.speed(totalUp)
        let rates = [down.isEmpty ? nil : "↓ \(down)", up.isEmpty ? nil : "↑ \(up)"]
            .compactMap { $0 }.joined(separator: "   ")

        let count = displayed.count == torrents.count
            ? "\(torrents.count) torrents"
            : "\(displayed.count) of \(torrents.count) torrents"

        // Aggregate counts per status group (only non-zero groups shown).
        var downloading = 0, seeding = 0, stopped = 0, checking = 0, errored = 0
        for t in torrents {
            if t.hasError { errored += 1 }
            switch t.status {
            case .downloading: downloading += 1
            case .seeding: seeding += 1
            case .stopped: stopped += 1
            case .checking, .checkWait: checking += 1
            default: break
            }
        }
        let breakdown = [
            downloading > 0 ? "DL \(downloading)" : nil,
            seeding > 0 ? "Seed \(seeding)" : nil,
            checking > 0 ? "Check \(checking)" : nil,
            stopped > 0 ? "Stopped \(stopped)" : nil,
            errored > 0 ? "Err \(errored)" : nil,
        ].compactMap { $0 }.joined(separator: " · ")

        var parts = [count]
        if !breakdown.isEmpty { parts.append(breakdown) }
        if !rates.isEmpty { parts.append(rates) }
        if let free = refresh.freeSpace, free >= 0 { parts.append("Free: \(Formatters.size(free))") }
        parts.append(connection)
        statusLabel.stringValue = parts.joined(separator: "      ")
    }

    // MARK: - Sorting

    private func sortTorrents() {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else {
            torrents.sort { $0.addedDate < $1.addedDate }
            return
        }
        let ascending = descriptor.ascending
        torrents.sort { a, b in
            let result: Bool
            switch column {
            case .queue: result = a.queuePosition < b.queuePosition
            case .name: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: result = a.totalSize < b.totalSize
            case .status: result = a.statusRaw < b.statusRaw
            case .progress: result = a.percentDone < b.percentDone
            case .down: result = a.rateDownload < b.rateDownload
            case .up: result = a.rateUpload < b.rateUpload
            case .eta: result = a.eta < b.eta
            case .ratio: result = a.uploadRatio < b.uploadRatio
            case .ratioLimit: result = a.effectiveRatioLimit < b.effectiveRatioLimit
            case .added: result = a.addedDate < b.addedDate
            case .tracker: result = (a.trackerHost ?? "").localizedCaseInsensitiveCompare(b.trackerHost ?? "") == .orderedAscending
            }
            return ascending ? result : !result
        }
    }

    // MARK: - Selection helpers

    private func selectedTorrentIds() -> Set<Int> {
        Set(tableView.selectedRowIndexes.compactMap { row in
            displayed.indices.contains(row) ? displayed[row].id : nil
        })
    }

    var selectedTorrents: [Torrent] {
        tableView.selectedRowIndexes.compactMap { row in
            displayed.indices.contains(row) ? displayed[row] : nil
        }
    }

    func torrentAt(row: Int) -> Torrent? {
        displayed.indices.contains(row) ? displayed[row] : nil
    }

    // MARK: - Toast

    /// Show a brief, non-modal message near the bottom of the window that fades out
    /// on its own. Used for soft warnings (e.g. a mapped local path that isn't
    /// mounted) where a modal alert would be too heavy.
    func showToast(_ message: String) {
        guard let content = window?.contentView else { return }

        // Replace any visible toast immediately (e.g. copying a second value) rather
        // than letting the old one linger through its fade.
        activeToast?.removeFromSuperview()

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .labelColor   // black on light, white on dark — adapts to appearance
        label.font = .systemFont(ofSize: 18)
        label.alignment = .center
        // Wrap long messages over multiple lines instead of truncating.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = max(200, content.bounds.width * 0.85 - 28)

        let bg = ToastView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.material = .popover          // translucent: light in Light mode, dark in Dark mode
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.addSubview(label)
        content.addSubview(bg)
        activeToast = bg

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            bg.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bg.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            bg.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.85),
        ])

        // Fade in, hold ~2.4s, then auto-dismiss. A click dismisses early; the
        // ToastView guards against running its fade-out twice.
        bg.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            bg.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak bg] in
            bg?.dismiss()
        }
    }

    // MARK: - Detail pane

    private func updateDetail() {
        infoGrid.update(with: selectedTorrents)
    }

    /// Text shown for a torrent in a given column (shared by the cell view and the
    /// auto-size routine). Progress renders as a bar, so it returns "".
    private func cellText(for column: Column, torrent t: Torrent) -> String {
        switch column {
        case .queue: return "\(t.queuePosition + 1)"
        case .name: return t.name
        case .size: return Formatters.size(t.totalSize)
        case .status: return t.status.displayName
        case .progress: return ""
        case .down: return Formatters.speed(t.rateDownload)
        case .up: return Formatters.speed(t.rateUpload)
        case .eta: return t.etaDisplay
        case .ratio: return Formatters.ratio(t.uploadRatio)
        case .ratioLimit: return t.seedRatioDisplay
        case .added: return Formatters.date(t.addedDate)
        case .tracker: return t.trackerHost ?? "—"
        }
    }

    /// Colour the progress bar by torrent state (native polish).
    private func progressColor(for t: Torrent) -> NSColor {
        if t.hasError { return .systemRed }
        switch t.status {
        case .stopped: return .systemGray
        case .checking, .checkWait: return .systemOrange
        case .seeding: return .systemGreen
        default:
            return t.percentDone >= 1 ? .systemGreen : .controlAccentColor
        }
    }

    @objc private func didDoubleClickRow() {
        guard tableView.clickedRow >= 0,
              let t = selectionForAction().first else { return }
        // Open the item locally if a path mapping resolves it; otherwise the same
        // "Not available locally" toast the context-menu Open shows.
        revealOrOpen(remotePath: remotePath(for: t), open: true, warnIfUnmapped: true)
    }

    // MARK: - Errors

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Operation failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }

    // MARK: - Window observation (pause when hidden)

    private func observeWindow() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowHidden), name: NSWindow.didMiniaturizeNotification, object: window)
        nc.addObserver(self, selector: #selector(windowShown), name: NSWindow.didDeminiaturizeNotification, object: window)
    }

    @objc private func windowHidden() { refresh.setPaused(true) }
    @objc private func windowShown() { refresh.setPaused(false); refresh.refreshNow() }
}

// MARK: - Header menu

extension MainWindowController: NSMenuDelegate {}

// MARK: - Table data source / delegate

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === filesTable ? files.count : displayed.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView !== filesTable else { return }
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            UserDefaults.standard.set(key, forKey: "TorrentSortKey")
            UserDefaults.standard.set(descriptor.ascending, forKey: "TorrentSortAscending")
        }
        let ids = selectedTorrentIds()
        sortTorrents()
        rebuildDisplayed()
        tableView.reloadData()
        restoreSelection(ids)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as AnyObject) !== filesTable else { return }
        updateDetail()
        loadFilesIfNeeded()
        window?.toolbar?.validateVisibleItems()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === filesTable { return fileCell(for: tableColumn, row: row) }
        guard let column = Column(rawValue: tableColumn.identifier.rawValue),
              displayed.indices.contains(row) else { return nil }
        let t = displayed[row]

        if column == .progress {
            let cell = (tableView.makeView(withIdentifier: ProgressCellView.reuseIdentifier, owner: self) as? ProgressCellView)
                ?? {
                    let c = ProgressCellView()
                    c.identifier = ProgressCellView.reuseIdentifier
                    return c
                }()
            cell.configure(fraction: t.percentDone, color: progressColor(for: t))
            return cell
        }

        // Added: a self-adapting cell that re-picks compact vs full date in its own
        // `layout()` — so it flips live as the column is dragged wider/narrower.
        if column == .added {
            let cell = (tableView.makeView(withIdentifier: AddedDateCellView.reuseIdentifier, owner: self) as? AddedDateCellView)
                ?? {
                    let c = AddedDateCellView()
                    c.identifier = AddedDateCellView.reuseIdentifier
                    return c
                }()
            cell.configure(epoch: t.addedDate,
                           midThreshold: addedWidthThresholds.mid,
                           fullThreshold: addedWidthThresholds.full)
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("TextCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: NSFont.systemFontSize)
            c.addSubview(tf)
            c.textField = tf
            c.identifier = identifier
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let rightAligned: Set<Column> = [.queue, .size, .down, .up, .eta, .ratio, .ratioLimit]
        cell.textField?.stringValue = cellText(for: column, torrent: t)
        cell.textField?.alignment = rightAligned.contains(column) ? .right : .left
        return cell
    }
}

/// Cell for the Added column that adapts the date detail to the column width in
/// three steps: numeric date when narrow, numeric date+time at a middle width, and
/// the full date+time when wide. It decides in `layout()` — called on every frame
/// change, including continuously while the column is dragged — so the form flips
/// live without any resize notification.
final class AddedDateCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AddedDateCell")

    /// The three increasingly detailed date forms, in ascending width order.
    private enum Form { case date, dateTime, full }

    private let label = NSTextField(labelWithString: "")
    private var epoch: Double = 0
    private var midThreshold: CGFloat = 0
    private var fullThreshold: CGFloat = .greatestFiniteMagnitude
    /// Tracks the last form rendered so `layout()` only rewrites text on a change.
    private var currentForm: Form?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(epoch: Double, midThreshold: CGFloat, fullThreshold: CGFloat) {
        self.epoch = epoch
        self.midThreshold = midThreshold
        self.fullThreshold = fullThreshold
        currentForm = nil          // force a re-render for the (reused) cell
        applyText()
    }

    override func layout() {
        super.layout()
        applyText()
    }

    private func applyText() {
        let w = bounds.width
        let form: Form = w >= fullThreshold ? .full : (w >= midThreshold ? .dateTime : .date)
        guard currentForm != form else { return }
        currentForm = form
        switch form {
        case .date: label.stringValue = Formatters.compactDate(epoch)
        case .dateTime: label.stringValue = Formatters.compactDateTime(epoch)
        case .full: label.stringValue = Formatters.date(epoch)
        }
    }
}

/// Torrent list table — intercepts Return to trigger rename on single selection.
final class TorrentTableView: NSTableView {
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            onReturnKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Toast background that dismisses itself (fade out + remove) on click or when the
/// auto-timer fires, whichever comes first. The fade-out runs at most once.
final class ToastView: NSVisualEffectView {
    private var dismissed = false

    override func mouseDown(with event: NSEvent) { dismiss() }

    func dismiss() {
        guard !dismissed, superview != nil else { return }
        dismissed = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            self.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.removeFromSuperview()
        }
    }
}
