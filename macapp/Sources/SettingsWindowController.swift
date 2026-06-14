import AppKit

/// Native Settings window (⌘,) replacing the old hand-edited JSONC file. Two
/// panes: **Servers** (a list of connections with editable host/port/auth) and
/// **General** (poll interval + the default server). Edits mutate a working copy
/// of `AppConfig`; the working copy is persisted and applied live whenever it
/// changes, so there's no separate Save step.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// Called with the edited config after every change (persist + apply live).
    var onChange: ((AppConfig) -> Void)?

    /// Working copy being edited.
    private var config: AppConfig

    // Servers pane.
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
    private let defaultServerPopup = NSPopUpButton()

    init(config: AppConfig) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        window.center()
        window.contentView = buildTabView()
        reloadServerList()
        reloadGeneral()
        selectServer(at: config.servers.isEmpty ? nil : 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildTabView() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let serversItem = NSTabViewItem(identifier: "servers")
        serversItem.label = "Servers"
        serversItem.view = buildServersPane()
        tabView.addTabViewItem(serversItem)

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = buildGeneralPane()
        tabView.addTabViewItem(generalItem)

        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func buildServersPane() -> NSView {
        let pane = NSView()

        // Left: the server list with +/- buttons beneath it.
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Server"
        serverTable.addTableColumn(column)
        serverTable.headerView = nil
        serverTable.dataSource = self
        serverTable.delegate = self
        serverTable.allowsEmptySelection = true
        serverTable.usesAutomaticRowHeights = false

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

        pane.addSubview(scroll)
        pane.addSubview(addButton)
        pane.addSubview(removeButton)
        pane.addSubview(form)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 160),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),

            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 24),

            form.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
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

        defaultServerPopup.target = self
        defaultServerPopup.action = #selector(defaultServerChanged)

        let grid = NSGridView(views: [
            [label("Refresh every:"), stack([refreshField, refreshStepper, label("seconds")])],
            [label("Default server:"), defaultServerPopup],
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
        let l = NSTextField(labelWithString: text)
        return l
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
        selectServer(at: config.servers.count - 1)
        commit()
    }

    @objc private func removeServer() {
        guard let i = selectedIndex, config.servers.count > 1 else { return }
        let removed = config.servers.remove(at: i)
        if config.currentServer == removed.name {
            config.currentServer = config.servers.first?.name
        }
        reloadServerList()
        selectServer(at: min(i, config.servers.count - 1))
        reloadGeneral()
        commit()
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
        reloadGeneral()
        commit()
    }

    // MARK: - General

    private func reloadGeneral() {
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        refreshStepper.doubleValue = config.refreshSeconds
        defaultServerPopup.removeAllItems()
        defaultServerPopup.addItems(withTitles: config.serverNames)
        if let current = config.currentServer, config.serverNames.contains(current) {
            defaultServerPopup.selectItem(withTitle: current)
        } else if let first = config.serverNames.first {
            defaultServerPopup.selectItem(withTitle: first)
        }
    }

    @objc private func refreshChanged() {
        config.refreshSeconds = max(1, Double(refreshField.stringValue) ?? config.refreshSeconds)
        refreshStepper.doubleValue = config.refreshSeconds
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        commit()
    }

    @objc private func stepperChanged() {
        config.refreshSeconds = max(1, refreshStepper.doubleValue)
        refreshField.stringValue = String(format: "%g", config.refreshSeconds)
        commit()
    }

    @objc private func defaultServerChanged() {
        config.currentServer = defaultServerPopup.titleOfSelectedItem
        commit()
    }

    // MARK: - Persist + apply

    /// Normalize the working copy through `AppConfig.init` (clamps, fallbacks) and
    /// publish it to the app.
    private func commit() {
        let normalized = AppConfig(servers: config.servers,
                                   refreshSeconds: config.refreshSeconds,
                                   currentServer: config.currentServer)
        onChange?(normalized)
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
