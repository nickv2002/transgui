import AppKit

/// Toolbar, context menu, and the start/stop/force-start/rename/move actions.
extension MainWindowController: NSToolbarDelegate {
    private enum ToolbarID {
        static let add = NSToolbarItem.Identifier("add")
        static let start = NSToolbarItem.Identifier("start")
        static let stop = NSToolbarItem.Identifier("stop")
        static let forceStart = NSToolbarItem.Identifier("forceStart")
        static let rename = NSToolbarItem.Identifier("rename")
        static let move = NSToolbarItem.Identifier("move")
        static let verify = NSToolbarItem.Identifier("verify")
        static let remove = NSToolbarItem.Identifier("remove")
        static let search = NSToolbarItem.Identifier("search")
    }

    func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.add, .space,
         ToolbarID.start, ToolbarID.stop, ToolbarID.forceStart,
         ToolbarID.rename, ToolbarID.move, ToolbarID.verify, ToolbarID.remove,
         .flexibleSpace, ToolbarID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The live-filter search box.
        if itemIdentifier == ToolbarID.search {
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = searchPlaceholder
            item.searchField.sendsWholeSearchString = false
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.searchMenuTemplate = searchModeMenu()
            searchField = item.searchField
            return item
        }

        // The Add pull-down: primary click adds a file; the menu offers file/link.
        if itemIdentifier == ToolbarID.add {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            item.isBordered = true
            item.target = self
            item.action = #selector(addFile(_:))
            item.menu = addMenu()
            return item
        }

        let spec: (label: String, symbol: String, action: Selector)?
        switch itemIdentifier {
        case ToolbarID.start: spec = ("Start", "play.fill", #selector(startSelected(_:)))
        case ToolbarID.stop: spec = ("Stop", "stop.fill", #selector(stopSelected(_:)))
        case ToolbarID.forceStart: spec = ("Force Start", "forward.fill", #selector(forceStartSelected(_:)))
        case ToolbarID.rename: spec = ("Rename", "pencil", #selector(renameSelected(_:)))
        case ToolbarID.move: spec = ("Move", "folder", #selector(moveSelected(_:)))
        case ToolbarID.verify: spec = ("Verify", "checkmark.shield", #selector(verifySelected(_:)))
        case ToolbarID.remove: spec = ("Remove", "trash", #selector(removeSelected(_:)))
        default: spec = nil
        }
        guard let spec else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = spec.action
        item.isBordered = true
        return item
    }

    /// Pull-down for the Add toolbar item: torrent file or magnet/URL.
    private func addMenu() -> NSMenu {
        let menu = NSMenu()
        let file = menu.addItem(withTitle: "Add Torrent File…", action: #selector(addFile(_:)), keyEquivalent: "")
        file.target = self
        let link = menu.addItem(withTitle: "Add Magnet or URL…", action: #selector(addLink(_:)), keyEquivalent: "")
        link.target = self
        return menu
    }

    /// The magnifying-glass dropdown menu inside the search field: pick the match
    /// mode (Fuzzy vs Exact). Checkmarks are kept current in `validateMenuItem`.
    private func searchModeMenu() -> NSMenu {
        let menu = NSMenu()
        let fuzzy = menu.addItem(withTitle: "Fuzzy Match",
                                 action: #selector(searchModeChanged(_:)), keyEquivalent: "")
        fuzzy.tag = SearchMode.fuzzy.rawValue
        fuzzy.target = self
        let exact = menu.addItem(withTitle: "Exact Match",
                                 action: #selector(searchModeChanged(_:)), keyEquivalent: "")
        exact.tag = SearchMode.exact.rawValue
        exact.target = self
        return menu
    }

    @objc func searchModeChanged(_ sender: NSMenuItem) {
        guard let mode = SearchMode(rawValue: sender.tag) else { return }
        setSearchMode(mode)
    }

    func rowContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Start", action: #selector(startSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Stop", action: #selector(stopSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Force Start", action: #selector(forceStartSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Verify", action: #selector(verifySelected(_:)), keyEquivalent: "")

        // Queue submenu.
        let queueItem = menu.addItem(withTitle: "Queue", action: nil, keyEquivalent: "")
        let queueMenu = NSMenu()
        let queueSpecs: [(String, Int)] = [
            ("Move to Top", QueueMoveTag.top), ("Move Up", QueueMoveTag.up),
            ("Move Down", QueueMoveTag.down), ("Move to Bottom", QueueMoveTag.bottom),
        ]
        for (title, tag) in queueSpecs {
            let item = queueMenu.addItem(withTitle: title, action: #selector(queueMoveSelected(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
        }
        queueItem.submenu = queueMenu

        // Priority submenu.
        let priorityItem = menu.addItem(withTitle: "Priority", action: nil, keyEquivalent: "")
        let priorityMenu = NSMenu()
        for priority in [BandwidthPriority.high, .normal, .low] {
            let item = priorityMenu.addItem(withTitle: priority.displayName, action: #selector(setPrioritySelected(_:)), keyEquivalent: "")
            item.tag = priority.rawValue
            item.target = self
        }
        priorityItem.submenu = priorityMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinderSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open", action: #selector(openSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename…", action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move…", action: #selector(moveSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove…", action: #selector(removeSelected(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    /// Tags used to carry the queue direction through a single menu selector.
    private enum QueueMoveTag {
        static let top = 0, up = 1, down = 2, bottom = 3
    }

    // MARK: - Enablement

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(action: item.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Reflect the active search mode as a checkmark in the search-field menu.
        if menuItem.action == #selector(searchModeChanged(_:)) {
            menuItem.state = (menuItem.tag == searchMode.rawValue) ? .on : .off
            return true
        }
        return validate(action: menuItem.action)
    }

    private func validate(action: Selector?) -> Bool {
        // The search field is always enabled, regardless of row selection.
        if action == #selector(searchChanged(_:)) { return true }
        // Adding is always available (independent of the row selection).
        if action == #selector(addFile(_:)) || action == #selector(addLink(_:)) { return true }
        // Files-tab Reveal/Open: enabled only when a mapping resolves the file path.
        if action == #selector(revealFileInFinder(_:)) || action == #selector(openFile(_:)) {
            guard let remote = targetedFileRemotePath() else { return false }
            return refresh.activeServerConfig.mapRemoteToLocal(remote) != nil
        }
        let selection = selectionForAction()
        guard !selection.isEmpty else { return false }
        switch action {
        case #selector(revealInFinderSelected(_:)), #selector(openSelected(_:)):
            // Enabled only when a mapping resolves the torrent's remote path.
            guard let t = selection.first else { return false }
            return refresh.activeServerConfig.mapRemoteToLocal(remotePath(for: t)) != nil
        case #selector(startSelected(_:)):
            return selection.contains { !$0.status.isActive }
        case #selector(stopSelected(_:)):
            return selection.contains { $0.status.isActive }
        case #selector(forceStartSelected(_:)):
            return true
        case #selector(renameSelected(_:)), #selector(moveSelected(_:)):
            return selection.count == 1
        case #selector(verifySelected(_:)), #selector(removeSelected(_:)),
             #selector(queueMoveSelected(_:)), #selector(setPrioritySelected(_:)):
            return true
        default:
            return true
        }
    }

    /// The torrents an action targets — the right-clicked row if it isn't part of
    /// the current selection, otherwise the full selection.
    func selectionForAction() -> [Torrent] {
        let clicked = clickedTorrent()
        let selected = selectedTorrents
        if let clicked, !selected.contains(where: { $0.id == clicked.id }) {
            return [clicked]
        }
        return selected
    }

    // MARK: - Actions

    @objc func startSelected(_ sender: Any?) {
        let ids = selectionForAction().map(\.id)
        runRPC { try await $0.start(ids: ids) }
    }

    @objc func stopSelected(_ sender: Any?) {
        let ids = selectionForAction().map(\.id)
        runRPC { try await $0.stop(ids: ids) }
    }

    @objc func forceStartSelected(_ sender: Any?) {
        let ids = selectionForAction().map(\.id)
        runRPC { try await $0.startNow(ids: ids) }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let t = selectionForAction().first else { return }
        promptText(title: "Rename Torrent",
                   message: "New name for “\(t.name)”:",
                   defaultValue: t.name) { [weak self] newName in
            guard let newName, newName != t.name, !newName.isEmpty else { return }
            self?.runRPC { try await $0.rename(id: t.id, path: t.name, name: newName) }
        }
    }

    @objc func moveSelected(_ sender: Any?) {
        guard let t = selectionForAction().first else { return }
        promptText(title: "Move Torrent Data",
                   message: "New location on the server for “\(t.name)”:",
                   defaultValue: t.downloadDir) { [weak self] location in
            guard let location, !location.isEmpty, location != t.downloadDir else { return }
            self?.runRPC { try await $0.setLocation(ids: [t.id], location: location, move: true) }
        }
    }

    @objc func verifySelected(_ sender: Any?) {
        let ids = selectionForAction().map(\.id)
        guard !ids.isEmpty else { return }
        runRPC { try await $0.verify(ids: ids) }
    }

    @objc func queueMoveSelected(_ sender: NSMenuItem) {
        let ids = selectionForAction().map(\.id)
        guard !ids.isEmpty else { return }
        let move: TransmissionClient.QueueMove
        switch sender.tag {
        case QueueMoveTag.top: move = .top
        case QueueMoveTag.up: move = .up
        case QueueMoveTag.down: move = .down
        default: move = .bottom
        }
        runRPC { try await $0.queueMove(ids: ids, to: move) }
    }

    @objc func setPrioritySelected(_ sender: NSMenuItem) {
        let ids = selectionForAction().map(\.id)
        guard !ids.isEmpty, let priority = BandwidthPriority(rawValue: sender.tag) else { return }
        runRPC { try await $0.setBandwidthPriority(ids: ids, priority: priority) }
    }

    @objc func removeSelected(_ sender: Any?) {
        let targets = selectionForAction()
        guard !targets.isEmpty, let window else { return }
        let ids = targets.map(\.id)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "Remove “\(targets[0].name)”?"
            : "Remove \(targets.count) torrents?"
        alert.informativeText = "This removes the torrent from Transmission. Choose “Remove + Data” to also delete the downloaded files from the server — this cannot be undone."
        // Default (leftmost, also the Return key) is the non-destructive choice.
        alert.addButton(withTitle: "Remove")
        let deleteButton = alert.addButton(withTitle: "Remove + Data")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) { deleteButton.hasDestructiveAction = true }

        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.runRPC { try await $0.remove(ids: ids, deleteLocalData: false) }
            case .alertSecondButtonReturn:
                self?.confirmDeleteWithData(ids: ids, count: targets.count)
            default:
                break   // Cancel
            }
        }
    }

    /// Second confirmation before the irreversible "delete files too" path.
    private func confirmDeleteWithData(ids: [Int], count: Int) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = count == 1
            ? "Delete the downloaded files too?"
            : "Delete the downloaded files for \(count) torrents too?"
        alert.informativeText = "The data will be permanently deleted from the server."
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: "Delete Files")
        if #available(macOS 11.0, *) { confirm.hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.runRPC { try await $0.remove(ids: ids, deleteLocalData: true) }
        }
    }

    // MARK: - Reveal / Open (remote→local path mapping)

    @objc func revealInFinderSelected(_ sender: Any?) {
        guard let t = selectionForAction().first else { return }
        revealOrOpen(remotePath: remotePath(for: t), open: false)
    }

    @objc func openSelected(_ sender: Any?) {
        guard let t = selectionForAction().first else { return }
        revealOrOpen(remotePath: remotePath(for: t), open: true)
    }

    /// A torrent's remote path: its (normalized) download dir plus the top-level
    /// file/folder name the daemon reports.
    func remotePath(for t: Torrent) -> String {
        t.normalizedDownloadDir + "/" + t.name
    }

    /// Translate `remotePath` to a local one via the active server's mappings, then
    /// reveal it in Finder or open it. If a mapping applies but the file isn't
    /// present locally (not mounted/synced), show a non-modal toast instead.
    /// Callers should only invoke this when a mapping exists (the menu items are
    /// disabled otherwise).
    func revealOrOpen(remotePath: String, open: Bool, warnIfUnmapped: Bool = false) {
        guard let local = refresh.activeServerConfig.mapRemoteToLocal(remotePath) else {
            // Double-click (warnIfUnmapped) gets the same "not available" toast the
            // context-menu Open shows; the menu items themselves stay disabled when
            // unmapped, so they pass warnIfUnmapped = false and just no-op.
            if warnIfUnmapped { showToast("Not available locally: \(remotePath)") }
            return
        }
        guard FileManager.default.fileExists(atPath: local) else {
            showToast("Not available locally: \(local)")
            return
        }
        let url = URL(fileURLWithPath: local)
        if open {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Helpers

    private func clickedTorrent() -> Torrent? {
        torrentAt(row: tableView.clickedRow)
    }

    /// Runs an RPC call against the live client, then refreshes. Errors surface
    /// as an alert.
    private func runRPC(_ body: @escaping (TransmissionClient) async throws -> Void) {
        guard let client = refresh.activeClient else { return }
        Task { @MainActor in
            do {
                try await body(client)
                refresh.refreshNow()
            } catch {
                showError(error)
            }
        }
    }

    /// A modal text-entry sheet. Calls `completion` with the entered string, or
    /// nil if cancelled.
    private func promptText(title: String, message: String, defaultValue: String,
                            completion: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        field.lineBreakMode = .byTruncatingHead
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}
