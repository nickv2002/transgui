import AppKit

/// Top-level window: a torrent table, a detail pane, a toolbar of actions, and a
/// status bar. Owns the `RefreshController` that drives live updates.
final class MainWindowController: NSWindowController {
    let refresh: RefreshController

    let tableView = NSTableView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    var torrents: [Torrent] = []

    // Column identifiers double as sort keys.
    private enum Column: String, CaseIterable {
        case name, status, progress, down, up, eta, ratio

        var title: String {
            switch self {
            case .name: return "Name"
            case .status: return "Status"
            case .progress: return "Progress"
            case .down: return "↓ Speed"
            case .up: return "↑ Speed"
            case .eta: return "ETA"
            case .ratio: return "Ratio"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 260
            case .status: return 110
            case .progress: return 90
            case .down, .up: return 80
            case .eta: return 70
            case .ratio: return 60
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
        window.setFrameAutosaveName("MainWindow")
        window.center()
        super.init(window: window)

        buildToolbar()
        buildLayout()
        wireRefresh()
        observeWindow()
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

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // Detail pane.
        detailLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailLabel.textColor = .labelColor
        detailLabel.stringValue = "No torrent selected."
        let detailScroll = NSScrollView()
        let detailContainer = NSView()
        detailContainer.addSubview(detailLabel)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 8),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor, constant: -8),
        ])
        detailScroll.documentView = detailContainer
        detailScroll.hasVerticalScroller = true
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailContainer.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])

        // Vertical split between table and detail.
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailScroll)
        split.translatesAutoresizingMaskIntoConstraints = false

        // Status bar.
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Idle"
        let statusBar = NSView()
        statusBar.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Explicit constraints: split fills the window above a fixed-height status
        // bar. (An NSStackView here collapsed the split — and the table inside it —
        // to zero height because the split view has no intrinsic content size.)
        let content = NSView()
        content.addSubview(split)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        // Give the detail pane a sensible starting height once laid out.
        DispatchQueue.main.async {
            let h = split.bounds.height
            if h > 200 { split.setPosition(h - 170, ofDividerAt: 0) }
        }
    }

    private func configureColumns() {
        for column in Column.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(col)
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
    }

    private func applyTorrents(_ incoming: [Torrent]) {
        // Preserve the user's selection across reloads by id.
        let selectedIds = selectedTorrentIds()
        torrents = incoming
        sortTorrents()
        tableView.reloadData()

        if !selectedIds.isEmpty {
            let rows = IndexSet(torrents.enumerated()
                .filter { selectedIds.contains($0.element.id) }
                .map { $0.offset })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        updateDetail()
        updateStatusBar(state: refresh.state)
        window?.toolbar?.validateVisibleItems()
    }

    private func updateStatusBar(state: RefreshController.State) {
        let connection: String
        switch state {
        case .idle: connection = "Idle"
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

        var parts = ["\(torrents.count) torrents", connection]
        if !rates.isEmpty { parts.insert(rates, at: 1) }
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
            case .name: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .status: result = a.statusRaw < b.statusRaw
            case .progress: result = a.percentDone < b.percentDone
            case .down: result = a.rateDownload < b.rateDownload
            case .up: result = a.rateUpload < b.rateUpload
            case .eta: result = a.eta < b.eta
            case .ratio: result = a.uploadRatio < b.uploadRatio
            }
            return ascending ? result : !result
        }
    }

    // MARK: - Selection helpers

    private func selectedTorrentIds() -> Set<Int> {
        Set(tableView.selectedRowIndexes.compactMap { row in
            torrents.indices.contains(row) ? torrents[row].id : nil
        })
    }

    var selectedTorrents: [Torrent] {
        tableView.selectedRowIndexes.compactMap { row in
            torrents.indices.contains(row) ? torrents[row] : nil
        }
    }

    func torrentAt(row: Int) -> Torrent? {
        torrents.indices.contains(row) ? torrents[row] : nil
    }

    // MARK: - Detail pane

    private func updateDetail() {
        guard let t = selectedTorrents.first else {
            detailLabel.stringValue = selectedTorrents.isEmpty
                ? "No torrent selected."
                : "\(selectedTorrents.count) torrents selected."
            return
        }
        let downloaded = t.sizeWhenDone - t.leftUntilDone
        var lines: [String] = []
        lines.append("Name:        \(t.name)")
        lines.append("Status:      \(t.status.displayName)")
        if !t.errorString.isEmpty { lines.append("Error:       \(t.errorString)") }
        lines.append("Progress:    \(Formatters.percent(t.percentDone))")
        lines.append("Size:        \(Formatters.size(t.totalSize)) (want \(Formatters.size(t.sizeWhenDone)))")
        lines.append("Downloaded:  \(Formatters.size(downloaded))")
        lines.append("Ratio:       \(Formatters.ratio(t.uploadRatio))")
        lines.append("Download:    \(Formatters.speed(t.rateDownload).isEmpty ? "—" : Formatters.speed(t.rateDownload))")
        lines.append("Upload:      \(Formatters.speed(t.rateUpload).isEmpty ? "—" : Formatters.speed(t.rateUpload))")
        lines.append("ETA:         \(Formatters.eta(t.eta).isEmpty ? "—" : Formatters.eta(t.eta))")
        lines.append("Location:    \(t.downloadDir)")
        lines.append("Peers:       \(t.peersConnected) connected (↓\(t.peersSendingToUs) ↑\(t.peersGettingFromUs))")
        lines.append("Added:       \(Formatters.date(t.addedDate))")
        lines.append("Hash:        \(t.hashString)")
        detailLabel.stringValue = lines.joined(separator: "\n")
    }

    @objc private func didDoubleClickRow() {
        guard tableView.clickedRow >= 0 else { return }
        renameSelected(nil)
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

// MARK: - Table data source / delegate

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { torrents.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let ids = selectedTorrentIds()
        sortTorrents()
        tableView.reloadData()
        let rows = IndexSet(torrents.enumerated().filter { ids.contains($0.element.id) }.map { $0.offset })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
        window?.toolbar?.validateVisibleItems()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              torrents.indices.contains(row) else { return nil }
        let t = torrents[row]

        if column == .progress {
            let cell = (tableView.makeView(withIdentifier: ProgressCellView.reuseIdentifier, owner: self) as? ProgressCellView)
                ?? {
                    let c = ProgressCellView()
                    c.identifier = ProgressCellView.reuseIdentifier
                    return c
                }()
            cell.configure(fraction: t.percentDone)
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

        let value: String
        var alignment: NSTextAlignment = .left
        switch column {
        case .name: value = t.name
        case .status: value = t.status.displayName
        case .progress: value = ""
        case .down: value = Formatters.speed(t.rateDownload); alignment = .right
        case .up: value = Formatters.speed(t.rateUpload); alignment = .right
        case .eta: value = Formatters.eta(t.eta); alignment = .right
        case .ratio: value = Formatters.ratio(t.uploadRatio); alignment = .right
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = alignment
        return cell
    }
}
