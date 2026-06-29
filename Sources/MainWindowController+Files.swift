import AppKit

/// The Files tab of the detail pane: a per-file table with a "wanted" checkbox,
/// size, progress, and priority (mutated via `files-wanted` / `priority-*`).
extension MainWindowController {
    /// Column identifiers for the files table.
    enum FileColumn: String, CaseIterable {
        case wanted, name, size, progress, priority

        var title: String {
            switch self {
            case .wanted: return ""
            case .name: return "Name"
            case .size: return "Size"
            case .progress: return "Progress"
            case .priority: return "Priority"
            }
        }

        var width: CGFloat {
            switch self {
            case .wanted: return 26
            case .name: return 320
            case .size: return 80
            case .progress: return 90
            case .priority: return 70
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    }

    // MARK: - Building

    private static let filesColumnWidthsKey = "FilesColumnWidths"

    func buildFilesTable() -> NSScrollView {
        for column in FileColumn.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width
            filesTable.addTableColumn(col)
        }
        restoreFilesColumnWidths()
        NotificationCenter.default.addObserver(self, selector: #selector(filesColumnResized(_:)),
                                               name: NSTableView.columnDidResizeNotification,
                                               object: filesTable)

        filesTable.usesAlternatingRowBackgroundColors = true
        filesTable.allowsMultipleSelection = true
        filesTable.rowHeight = 20
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.menu = filesContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = filesTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private func restoreFilesColumnWidths() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.filesColumnWidthsKey) else { return }
        for col in filesTable.tableColumns {
            if let width = dict[col.identifier.rawValue] as? CGFloat {
                col.width = width
            }
        }
    }

    @objc private func filesColumnResized(_ notification: Notification) {
        var dict: [String: CGFloat] = [:]
        for col in filesTable.tableColumns {
            dict[col.identifier.rawValue] = col.width
        }
        UserDefaults.standard.set(dict, forKey: Self.filesColumnWidthsKey)
    }

    private func tableView(_ table: NSTableView, addColumn col: NSTableColumn) {
        table.addTableColumn(col)
    }

    private func filesContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Download (Wanted)", action: #selector(setFilesWantedAction(_:)), keyEquivalent: "").tag = 1
        menu.addItem(withTitle: "Skip (Unwanted)", action: #selector(setFilesWantedAction(_:)), keyEquivalent: "").tag = 0
        menu.addItem(.separator())
        let priorityItem = menu.addItem(withTitle: "Priority", action: nil, keyEquivalent: "")
        let priorityMenu = NSMenu()
        for priority in [FilePriority.high, .normal, .low] {
            let item = priorityMenu.addItem(withTitle: priority.displayName, action: #selector(setFilePriorityAction(_:)), keyEquivalent: "")
            item.tag = priority.rawValue
            item.target = self
        }
        priorityItem.submenu = priorityMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename…", action: #selector(renameFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFileInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open", action: #selector(openFile(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    // MARK: - Reveal / Open a single file (remote→local path mapping)

    @objc func revealFileInFinder(_ sender: Any?) {
        guard let remote = targetedFileRemotePath() else { return }
        revealOrOpen(remotePath: remote, open: false)
    }

    @objc func openFile(_ sender: Any?) {
        guard let remote = targetedFileRemotePath() else { return }
        revealOrOpen(remotePath: remote, open: true)
    }

    @objc func renameFile(_ sender: Any?) {
        guard let torrent = selectedTorrents.first, let file = targetedSingleFile() else { return }
        let torrentId = torrent.id
        let oldPath = file.name
        let oldName = (oldPath as NSString).lastPathComponent
        promptText(title: "Rename File",
                   message: "New name for \u{201C}\(oldName)\u{201D}:",
                   defaultValue: oldName) { [weak self] newName in
            guard let newName, newName != oldName, !newName.isEmpty else { return }
            self?.runFilesRPC { try await $0.rename(id: torrentId, path: oldPath, name: newName) }
        }
    }

    /// The remote path of the single targeted file (right-clicked row, else a lone
    /// selection): the current torrent's download dir + the file's relative name.
    /// `nil` when no single file is targeted.
    func targetedFileRemotePath() -> String? {
        guard let torrent = selectedTorrents.first, let file = targetedSingleFile() else { return nil }
        return torrent.normalizedDownloadDir + "/" + file.name
    }

    func targetedSingleFile() -> TorrentFile? {
        let clicked = filesTable.clickedRow
        let selected = filesTable.selectedRowIndexes
        let row: Int
        if clicked >= 0, !selected.contains(clicked) {
            row = clicked
        } else if selected.count == 1, let only = selected.first {
            row = only
        } else {
            return nil
        }
        return files.indices.contains(row) ? files[row] : nil
    }

    // MARK: - Fetching

    /// Refresh the Files tab for the current main-table selection. Fetches only
    /// when exactly one torrent is selected and the Files tab is visible; otherwise
    /// clears the list. Cheap to call on every poll and selection change.
    func loadFilesIfNeeded() {
        let isFilesTabVisible = detailTabView.selectedTabViewItem?.identifier as? String == "files"
        let selection = selectedTorrents
        guard isFilesTabVisible, selection.count == 1, let torrent = selection.first else {
            if filesTorrentId != nil || !files.isEmpty {
                filesFetchTask?.cancel()
                filesTorrentId = nil
                files = []
                reloadFilesData()
            }
            return
        }

        // Changed torrent: drop the stale list immediately so we don't show another
        // torrent's files while the new ones load.
        if filesTorrentId != torrent.id {
            filesTorrentId = torrent.id
            files = []
            reloadFilesData()
        }

        guard let client = refresh.activeClient else { return }
        let id = torrent.id
        filesFetchTask?.cancel()
        filesFetchTask = Task { @MainActor in
            do {
                let fetched = try await client.fetchFiles(id: id)
                guard !Task.isCancelled, self.filesTorrentId == id else { return }
                self.files = fetched
                self.reloadFilesData()
            } catch {
                // Silent: the list poll surfaces connection errors already.
            }
        }
    }

    // MARK: - Actions

    /// Files the action targets: right-clicked row if outside the selection, else
    /// the whole selection.
    private func targetedFileIndices() -> [Int] {
        let clicked = filesTable.clickedRow
        let selected = filesTable.selectedRowIndexes
        if clicked >= 0, !selected.contains(clicked) {
            return files.indices.contains(clicked) ? [files[clicked].index] : []
        }
        return selected.compactMap { files.indices.contains($0) ? files[$0].index : nil }
    }

    @objc func setFilesWantedAction(_ sender: NSMenuItem) {
        guard let id = filesTorrentId else { return }
        let indices = targetedFileIndices()
        let wanted = sender.tag == 1
        runFilesRPC { try await $0.setFilesWanted(id: id, fileIndices: indices, wanted: wanted) }
    }

    @objc func setFilePriorityAction(_ sender: NSMenuItem) {
        guard let id = filesTorrentId, let priority = FilePriority(rawValue: sender.tag) else { return }
        let indices = targetedFileIndices()
        runFilesRPC { try await $0.setFilePriority(id: id, fileIndices: indices, priority: priority) }
    }

    /// Toggle "wanted" from the row checkbox.
    @objc func toggleFileWanted(_ sender: NSButton) {
        guard let id = filesTorrentId, files.indices.contains(sender.tag) else { return }
        let fileIndex = files[sender.tag].index
        let wanted = sender.state == .on
        runFilesRPC { try await $0.setFilesWanted(id: id, fileIndices: [fileIndex], wanted: wanted) }
    }

    /// Reload the files table, preserving the user's selection and focus.
    ///
    /// `NSTableView.reloadData()` drops `selectedRowIndexes` on this toolchain
    /// (the main table works around the same thing via `restoreSelection`), so a
    /// poll/RPC refresh would silently deselect the file the user picked. The file
    /// list keeps a stable order across refreshes (Transmission indexes files), so
    /// restoring by row index reselects the same files; indexes past the new row
    /// count are dropped.
    private func reloadFilesData() {
        let restoreFocus = window?.firstResponder === filesTable
        let selection = filesTable.selectedRowIndexes
        filesTable.reloadData()
        if !selection.isEmpty {
            let valid = selection.filteredIndexSet { $0 < files.count }
            if !valid.isEmpty { filesTable.selectRowIndexes(valid, byExtendingSelection: false) }
        }
        if restoreFocus { window?.makeFirstResponder(filesTable) }
    }

    /// Run a files RPC then re-fetch the file list to reflect the change.
    private func runFilesRPC(_ body: @escaping (TransmissionClient) async throws -> Void) {
        guard let client = refresh.activeClient, let id = filesTorrentId else { return }
        Task { @MainActor in
            do {
                try await body(client)
                let fetched = try await client.fetchFiles(id: id)
                guard self.filesTorrentId == id else { return }
                self.files = fetched
                self.reloadFilesData()
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Cell construction

    func fileCell(for tableColumn: NSTableColumn, row: Int) -> NSView? {
        guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue),
              files.indices.contains(row) else { return nil }
        let file = files[row]

        if column == .wanted {
            let id = NSUserInterfaceItemIdentifier("FileWantedCell")
            let check = (filesTable.makeView(withIdentifier: id, owner: self) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFileWanted(_:)))
                b.identifier = id
                return b
            }()
            check.tag = row
            check.state = file.wanted ? .on : .off
            return check
        }

        if column == .progress {
            let cell = (filesTable.makeView(withIdentifier: ProgressCellView.reuseIdentifier, owner: self) as? ProgressCellView)
                ?? {
                    let c = ProgressCellView()
                    c.identifier = ProgressCellView.reuseIdentifier
                    return c
                }()
            cell.configure(fraction: file.percentDone,
                           color: file.percentDone >= 1 ? .systemGreen : .controlAccentColor)
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("FileTextCell")
        let cell = (filesTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            c.addSubview(tf)
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        var alignment: NSTextAlignment = .left
        let value: String
        switch column {
        case .name: value = file.name
        case .size: value = Formatters.size(file.length); alignment = .right
        case .priority: value = file.wanted ? file.priority.displayName : "Skip"; alignment = .right
        case .wanted, .progress: value = ""
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = alignment
        cell.textField?.textColor = file.wanted ? .labelColor : .secondaryLabelColor
        return cell
    }
}

// MARK: - Tab switching

extension MainWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: "DetailTabIdentifier")
        }
        loadFilesIfNeeded()
    }
}

// MARK: - FilesTableView

/// NSTableView subclass that intercepts ↩ to trigger the rename-file action,
/// matching Finder's convention for renaming selected items.
final class FilesTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if noMods, event.charactersIgnoringModifiers == "\r" {
            NSApp.sendAction(#selector(MainWindowController.renameFile(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: event)
    }
}
