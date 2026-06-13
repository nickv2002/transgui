import AppKit

/// Toolbar, context menu, and the start/stop/force-start/rename/move actions.
extension MainWindowController: NSToolbarDelegate {
    private enum ToolbarID {
        static let start = NSToolbarItem.Identifier("start")
        static let stop = NSToolbarItem.Identifier("stop")
        static let forceStart = NSToolbarItem.Identifier("forceStart")
        static let rename = NSToolbarItem.Identifier("rename")
        static let move = NSToolbarItem.Identifier("move")
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
        [ToolbarID.start, ToolbarID.stop, ToolbarID.forceStart,
         ToolbarID.rename, ToolbarID.move, .flexibleSpace, ToolbarID.search]
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
            item.searchField.placeholderString = "Filter by name"
            item.searchField.sendsWholeSearchString = false
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchField = item.searchField
            return item
        }

        let spec: (label: String, symbol: String, action: Selector)?
        switch itemIdentifier {
        case ToolbarID.start: spec = ("Start", "play.fill", #selector(startSelected(_:)))
        case ToolbarID.stop: spec = ("Stop", "stop.fill", #selector(stopSelected(_:)))
        case ToolbarID.forceStart: spec = ("Force Start", "forward.fill", #selector(forceStartSelected(_:)))
        case ToolbarID.rename: spec = ("Rename", "pencil", #selector(renameSelected(_:)))
        case ToolbarID.move: spec = ("Move", "folder", #selector(moveSelected(_:)))
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

    func rowContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Start", action: #selector(startSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Stop", action: #selector(stopSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Force Start", action: #selector(forceStartSelected(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename…", action: #selector(renameSelected(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move…", action: #selector(moveSelected(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: - Enablement

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(action: item.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validate(action: menuItem.action)
    }

    private func validate(action: Selector?) -> Bool {
        // The search field is always enabled, regardless of row selection.
        if action == #selector(searchChanged(_:)) { return true }
        let selection = selectionForAction()
        guard !selection.isEmpty else { return false }
        switch action {
        case #selector(startSelected(_:)):
            return selection.contains { !$0.status.isActive }
        case #selector(stopSelected(_:)):
            return selection.contains { $0.status.isActive }
        case #selector(forceStartSelected(_:)):
            return true
        case #selector(renameSelected(_:)), #selector(moveSelected(_:)):
            return selection.count == 1
        default:
            return true
        }
    }

    /// The torrents an action targets — the right-clicked row if it isn't part of
    /// the current selection, otherwise the full selection.
    private func selectionForAction() -> [Torrent] {
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
