import AppKit

/// Native Settings window (⌘,) replacing the old hand-edited JSONC file. Two
/// panes: **Servers** (a default-server picker, a list of connections with
/// editable host/port/auth, plus Test Connection / Save) and **General** (poll
/// interval).
///
/// Edits mutate an in-memory working copy of `AppConfig`. Nothing is persisted or
/// applied to the live connection until the user presses **Save** — closing with
/// unsaved changes prompts to save or discard.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called with the edited config when the user saves (persist + apply live).
    var onChange: ((AppConfig) -> Void)?

    /// Working copy being edited.
    private var config: AppConfig
    /// The last saved state, used to detect unsaved changes and to revert.
    private var savedBaseline: AppConfig

    // Servers pane.
    private let defaultServerPopup = NSPopUpButton()
    private let serverTable = NSTableView()
    private var selectedIndex: Int? { serverTable.selectedRow >= 0 ? serverTable.selectedRow : nil }
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let httpsCheckbox = NSButton(checkboxWithTitle: "Use HTTPS", target: nil, action: nil)
    private let rpcPathField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let removeButton = NSButton()
    private var detailFields: [NSControl] = []

    // General pane.
    private let refreshField = NSTextField()
    private let refreshStepper = NSStepper()

    // Bottom bar.
    private let testButton = NSButton()
    private let saveButton = NSButton()
    private let testSpinner = NSProgressIndicator()

    init(config: AppConfig) {
        self.config = config
        self.savedBaseline = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        reloadServerList()
        reloadDefaultServerPopup()
        reloadGeneral()
        selectServer(at: config.servers.isEmpty ? nil : 0)
        updateDirtyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-seed the working copy when the window is reopened, so it always reflects
    /// the current saved config (and never lingering discarded edits).
    func reset(to config: AppConfig) {
        self.config = config
        self.savedBaseline = config
        reloadServerList()
        reloadDefaultServerPopup()
        reloadGeneral()
        selectServer(at: config.servers.isEmpty ? nil : 0)
        updateDirtyState()
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        let serversItem = NSTabViewItem(identifier: "servers")
        serversItem.label = "Servers"
        serversItem.view = buildServersPane()
        tabView.addTabViewItem(serversItem)

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = buildGeneralPane()
        tabView.addTabViewItem(generalItem)

        setupBottomButtons()

        // Place Test Connection + Save *inside* the tab view's content box
        // (bottom-right), since they act on the settings shown in that box — not
        // in the window chrome below it.
        let container = NSView()
        container.addSubview(tabView)
        container.addSubview(testSpinner)
        container.addSubview(testButton)
        container.addSubview(saveButton)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: tabView.trailingAnchor, constant: -18),
            saveButton.bottomAnchor.constraint(equalTo: tabView.bottomAnchor, constant: -16),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            testButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            testButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            testSpinner.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -8),
            testSpinner.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
        return container
    }

    private func setupBottomButtons() {
        testSpinner.translatesAutoresizingMaskIntoConstraints = false
        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isDisplayedWhenStopped = false

        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.title = "Test Connection"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"   // Return triggers Save.
        saveButton.target = self
        saveButton.action = #selector(save)
    }

    private func buildServersPane() -> NSView {
        let pane = NSView()

        // Top: the default-server picker.
        defaultServerPopup.target = self
        defaultServerPopup.action = #selector(defaultServerChanged)
        let defaultRow = stack([label("Default server:"), defaultServerPopup])
        defaultRow.translatesAutoresizingMaskIntoConstraints = false

        // Left: the server list with +/- buttons beneath it.
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Server"
        serverTable.addTableColumn(column)
        serverTable.headerView = nil
        serverTable.dataSource = self
        serverTable.delegate = self
        serverTable.allowsEmptySelection = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = serverTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let addButton = NSButton()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .smallSquare
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add server")
        addButton.target = self
        addButton.action = #selector(addServer)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .smallSquare
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove server")
        removeButton.target = self
        removeButton.action = #selector(removeServer)

        // Right: the detail form for the selected server.
        let form = buildServerForm()

        pane.addSubview(defaultRow)
        pane.addSubview(scroll)
        pane.addSubview(addButton)
        pane.addSubview(removeButton)
        pane.addSubview(form)
        NSLayoutConstraint.activate([
            defaultRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            defaultRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: defaultRow.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 160),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),

            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 24),

            form.topAnchor.constraint(equalTo: scroll.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
        ])
        return pane
    }

    private func buildServerForm() -> NSView {
        for field in [nameField, hostField, portField, rpcPathField, usernameField] {
            field.target = self
            field.action = #selector(serverFieldChanged)
        }
        passwordField.target = self
        passwordField.action = #selector(serverFieldChanged)
        httpsCheckbox.target = self
        httpsCheckbox.action = #selector(serverFieldChanged)
        portField.placeholderString = "9091"
        rpcPathField.placeholderString = "/transmission/rpc"
        usernameField.placeholderString = "(none)"

        detailFields = [nameField, hostField, portField, httpsCheckbox,
                        rpcPathField, usernameField, passwordField]

        let grid = NSGridView(views: [
            [label("Name:"), nameField],
            [label("Host:"), hostField],
            [label("Port:"), portField],
            [NSView(), httpsCheckbox],
            [label("RPC Path:"), rpcPathField],
            [label("Username:"), usernameField],
            [label("Password:"), passwordField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 240
        return grid
    }

    private func buildGeneralPane() -> NSView {
        let pane = NSView()

        refreshField.translatesAutoresizingMaskIntoConstraints = false
        refreshField.target = self
        refreshField.action = #selector(refreshChanged)
        refreshField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        refreshStepper.target = self
        refreshStepper.action = #selector(stepperChanged)
        refreshStepper.minValue = 1
        refreshStepper.maxValue = 600
        refreshStepper.increment = 1
        refreshStepper.valueWraps = false

        let grid = NSGridView(views: [
            [label("Refresh every:"), stack([refreshField, refreshStepper, label("seconds")])],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        pane.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 24),
        ])
        return pane
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .firstBaseline
        return s
    }

    // MARK: - Server list

    private func reloadServerList() {
        serverTable.reloadData()
    }

    private func selectServer(at index: Int?) {
        if let index, config.servers.indices.contains(index) {
            serverTable.selectRowIndexes([index], byExtendingSelection: false)
        }
        loadDetail()
    }

    private func loadDetail() {
        let enabled = selectedIndex != nil
        for field in detailFields { field.isEnabled = enabled }
        removeButton.isEnabled = enabled && config.servers.count > 1
        testButton.isEnabled = enabled

        guard let i = selectedIndex else {
            nameField.stringValue = ""; hostField.stringValue = ""; portField.stringValue = ""
            rpcPathField.stringValue = ""; usernameField.stringValue = ""; passwordField.stringValue = ""
            httpsCheckbox.state = .off
            return
        }
        let s = config.servers[i]
        nameField.stringValue = s.name
        hostField.stringValue = s.host
        portField.stringValue = String(s.port)
        httpsCheckbox.state = s.useHTTPS ? .on : .off
        rpcPathField.stringValue = s.rpcPath
        usernameField.stringValue = s.username ?? ""
        passwordField.stringValue = s.password ?? ""
    }

    @objc private func addServer() {
        let base = "New Server"
        var name = base
        var n = 2
        while config.servers.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"; n += 1
        }
        config.servers.append(ServerConfig(
            name: name, host: "localhost", port: 9091,
            useHTTPS: false, rpcPath: "/transmission/rpc"))
        reloadServerList()
        reloadDefaultServerPopup()
        selectServer(at: config.servers.count - 1)
        updateDirtyState()
    }

    @objc private func removeServer() {
        guard let i = selectedIndex, config.servers.count > 1 else { return }
        let removed = config.servers.remove(at: i)
        if config.currentServer == removed.name {
            config.currentServer = config.servers.first?.name
        }
        reloadServerList()
        reloadDefaultServerPopup()
        selectServer(at: min(i, config.servers.count - 1))
        updateDirtyState()
    }

    @objc private func serverFieldChanged() {
        guard let i = selectedIndex else { return }
        var s = config.servers[i]
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let oldName = s.name
        s.name = trimmedName.isEmpty ? oldName : trimmedName
        // Keep names unique so the Server menu and `currentServer` stay unambiguous.
        if s.name != oldName && config.servers.contains(where: { $0.name == s.name }) {
            s.name = oldName
        }
        nameField.stringValue = s.name
        s.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        s.port = Int(portField.stringValue) ?? s.port
        s.useHTTPS = httpsCheckbox.state == .on
        let path = rpcPathField.stringValue.trimmingCharacters(in: .whitespaces)
        s.rpcPath = path.isEmpty ? "/transmission/rpc" : path
        s.username = usernameField.stringValue.isEmpty ? nil : usernameField.stringValue
        s.password = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue

        if s.name != oldName, config.currentServer == oldName {
            config.currentServer = s.name
        }
        config.servers[i] = s
        reloadServerList()
        reloadDefaultServerPopup()
        updateDirtyState()
    }

    @objc private func defaultServerChanged() {
        config.currentServer = defaultServerPopup.titleOfSelectedItem
        updateDirtyState()
    }

    private func reloadDefaultServerPopup() {
        let previous = config.currentServer
        defaultServerPopup.removeAllItems()
        defaultServerPopup.addItems(withTitles: config.serverNames)
        if let previous, config.serverNames.contains(previous) {
            defaultServerPopup.selectItem(withTitle: previous)
        } else if let first = config.serverNames.first {
            defaultServerPopup.selectItem(withTitle: first)
        }
    }

    // MARK: - General

    private func reloadGeneral() {
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        refreshStepper.doubleValue = config.refreshSeconds
    }

    @objc private func refreshChanged() {
        config.refreshSeconds = max(1, Double(refreshField.stringValue) ?? config.refreshSeconds)
        refreshStepper.doubleValue = config.refreshSeconds
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        updateDirtyState()
    }

    @objc private func stepperChanged() {
        config.refreshSeconds = max(1, refreshStepper.doubleValue)
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        updateDirtyState()
    }

    // MARK: - Dirty / Save

    /// The working copy, normalized through `AppConfig.init` (clamps + fallbacks).
    private func normalizedConfig() -> AppConfig {
        AppConfig(servers: config.servers,
                  refreshSeconds: config.refreshSeconds,
                  currentServer: config.currentServer)
    }

    private var hasUnsavedChanges: Bool { normalizedConfig() != savedBaseline }

    private func updateDirtyState() {
        saveButton.isEnabled = hasUnsavedChanges
    }

    @objc private func save() {
        let normalized = normalizedConfig()
        savedBaseline = normalized
        config = normalized
        onChange?(normalized)
        updateDirtyState()
    }

    // MARK: - Test Connection

    @objc private func testConnection() {
        guard let i = selectedIndex else { return }
        let server = config.servers[i]
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)

        Task { [weak self] in
            let result: Result<String, Error>
            do {
                let client = try TransmissionClient(server: server)
                let info = try await client.fetchSession()
                result = .success(info.version)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.testSpinner.stopAnimation(nil)
            self.testButton.isEnabled = self.selectedIndex != nil
            self.presentTestResult(result, server: server)
        }
    }

    private func presentTestResult(_ result: Result<String, Error>, server: ServerConfig) {
        let alert = NSAlert()
        switch result {
        case .success(let version):
            alert.alertStyle = .informational
            alert.messageText = "Connection succeeded"
            alert.informativeText = "Connected to \(server.host):\(server.port).\n"
                + "Transmission \(version)."
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Connection failed"
            alert.informativeText = ConnectionDiagnostics.message(for: error, server: server)
        }
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

// MARK: - Server table data source / delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { config.servers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("serverCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
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
        cell.textField?.stringValue = config.servers[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDetail()
    }
}

// MARK: - Tab + window delegate

extension SettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // Test Connection only applies to a server, so hide it off the Servers tab.
        let onServers = (tabViewItem?.identifier as? String) == "servers"
        testButton.isHidden = !onServers
        testSpinner.isHidden = !onServers
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to settings?"
        alert.informativeText = "Your changes haven’t been saved. Save them before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Save
            save()
            return true
        case .alertSecondButtonReturn:  // Discard
            reset(to: savedBaseline)
            return true
        default:                        // Cancel
            return false
        }
    }
}
