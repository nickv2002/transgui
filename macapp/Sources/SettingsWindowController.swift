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

    /// The editing model: working copy + saved baseline + all mutations.
    private var editor: SettingsEditor

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
    private let pathMappingsView = PlaceholderTextView()   // multi-line: one `remote=local` per line
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
        self.editor = SettingsEditor(config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        reloadEverything()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-seed the working copy when the window is reopened, so it always reflects
    /// the current saved config (and never lingering discarded edits).
    func reset(to config: AppConfig) {
        editor.reset(to: config)
        reloadEverything()
    }

    /// Refresh all UI from the editor and select the first server.
    private func reloadEverything() {
        reloadServerList()
        reloadDefaultServerPopup()
        reloadGeneral()
        selectServer(at: editor.serverCount == 0 ? nil : 0)
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
        // Deliberately NOT the default (Return) button: Return while editing a
        // field should commit that field, not save+apply the whole dialog. Save is
        // an explicit click only.
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
        for field in [nameField, hostField, portField, rpcPathField, usernameField, passwordField] {
            field.target = self
            field.action = #selector(serverFieldChanged)   // fires on end-editing (Tab/Return/focus loss)
            field.delegate = self                            // controlTextDidChange → live per-keystroke
        }
        httpsCheckbox.target = self
        httpsCheckbox.action = #selector(serverFieldChanged)
        hostField.placeholderString = "host, or comma/line-separated list of fallbacks"
        hostField.toolTip = "One host, or a comma- or line-separated list of fallbacks tried in "
            + "order — e.g. 10.0.1.2, n5.local, https://transmission.example.ts.net. "
            + "Each may include a scheme/port; the app connects to the first that responds."
        // Two-line wrapping field so a multi-host fallback list is visible at once.
        hostField.usesSingleLineMode = false
        hostField.lineBreakMode = .byWordWrapping
        hostField.cell?.wraps = true
        hostField.cell?.isScrollable = false
        hostField.maximumNumberOfLines = 3
        hostField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        portField.placeholderString = "9091"
        rpcPathField.placeholderString = "/transmission/rpc"
        usernameField.placeholderString = "(none)"

        detailFields = [nameField, hostField, portField, httpsCheckbox,
                        rpcPathField, usernameField, passwordField]

        let mappingsScroll = buildPathMappingsEditor()
        let caption = label("Remote→local, one per line.\ne.g.  /video=/Volumes/Video")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 0

        let grid = NSGridView(views: [
            [label("Name:"), nameField],
            [label("Host:"), hostField],
            [label("Port:"), portField],
            [NSView(), httpsCheckbox],
            [label("RPC Path:"), rpcPathField],
            [label("Username:"), usernameField],
            [label("Password:"), passwordField],
            [label("Path Mappings:"), mappingsScroll],
            [NSView(), caption],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 240
        // The mappings editor is multi-line; top-align its row so the label sits at
        // the first line rather than floating to the vertical centre.
        grid.row(at: 7).yPlacement = .top
        grid.row(at: 7).rowAlignment = .none
        return grid
    }

    /// A multi-line text editor (scrollable `NSTextView`) for the `remote=local`
    /// path-mapping lines — the native take on the legacy app's `edPaths` memo.
    private func buildPathMappingsEditor() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true

        pathMappingsView.delegate = self
        pathMappingsView.isRichText = false
        pathMappingsView.isAutomaticQuoteSubstitutionEnabled = false
        pathMappingsView.isAutomaticDashSubstitutionEnabled = false
        pathMappingsView.isAutomaticSpellingCorrectionEnabled = false
        pathMappingsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathMappingsView.placeholderString = "/video=/Volumes/Video\n/backup=/Volumes/backup"
        pathMappingsView.textContainerInset = NSSize(width: 2, height: 4)
        pathMappingsView.isVerticallyResizable = true
        pathMappingsView.isHorizontallyResizable = false
        pathMappingsView.autoresizingMask = [.width]
        pathMappingsView.textContainer?.widthTracksTextView = true
        scroll.documentView = pathMappingsView
        return scroll
    }

    private func buildGeneralPane() -> NSView {
        let pane = NSView()

        refreshField.translatesAutoresizingMaskIntoConstraints = false
        refreshField.target = self
        refreshField.action = #selector(refreshChanged)
        refreshField.delegate = self
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
        if let index, editor.servers.indices.contains(index) {
            serverTable.selectRowIndexes([index], byExtendingSelection: false)
        }
        loadDetail()
    }

    private func loadDetail() {
        let enabled = selectedIndex != nil
        for field in detailFields { field.isEnabled = enabled }
        pathMappingsView.isEditable = enabled
        pathMappingsView.isSelectable = enabled
        removeButton.isEnabled = enabled && editor.serverCount > 1
        // Test reads the form fields directly (see currentServerFromFields) and
        // validates the host itself, so keep it available whenever a row is shown.
        testButton.isEnabled = enabled

        guard let i = selectedIndex, let s = editor.server(at: i) else {
            nameField.stringValue = ""; hostField.stringValue = ""; portField.stringValue = ""
            rpcPathField.stringValue = ""; usernameField.stringValue = ""; passwordField.stringValue = ""
            httpsCheckbox.state = .off
            pathMappingsView.string = ""
            return
        }
        nameField.stringValue = s.name
        hostField.stringValue = s.host
        portField.stringValue = String(s.port)
        httpsCheckbox.state = s.useHTTPS ? .on : .off
        rpcPathField.stringValue = s.rpcPath
        usernameField.stringValue = s.username ?? ""
        passwordField.stringValue = s.password ?? ""
        pathMappingsView.string = PathMapping.format(s.pathMappings)
    }

    @objc private func addServer() {
        let index = editor.addServer()
        reloadServerList()
        reloadDefaultServerPopup()
        selectServer(at: index)
        updateDirtyState()
    }

    @objc private func removeServer() {
        guard let i = selectedIndex else { return }
        editor.removeServer(at: i)
        reloadServerList()
        reloadDefaultServerPopup()
        selectServer(at: min(i, editor.serverCount - 1))
        updateDirtyState()
    }

    /// End-of-edit (Tab/Return/focus loss): normalize the name and commit the row.
    @objc private func serverFieldChanged() {
        guard let i = selectedIndex else { return }
        let stored = editor.updateServer(at: i, to: currentServerFromFields(), normalizeName: true)
        // The normalized name may differ (trim / dedupe) — reflect it in the field.
        nameField.stringValue = stored.name
        updateRowLabel(at: i)
        reloadDefaultServerPopup()
        updateDirtyState()
    }

    @objc private func defaultServerChanged() {
        editor.setDefaultServer(defaultServerPopup.titleOfSelectedItem)
        updateDirtyState()
    }

    private func reloadDefaultServerPopup() {
        let previous = editor.currentServer
        defaultServerPopup.removeAllItems()
        defaultServerPopup.addItems(withTitles: editor.serverNames)
        if let previous, editor.serverNames.contains(previous) {
            defaultServerPopup.selectItem(withTitle: previous)
        } else if let first = editor.serverNames.first {
            defaultServerPopup.selectItem(withTitle: first)
        }
    }

    // MARK: - General

    private func reloadGeneral() {
        refreshField.stringValue = String(format: "%g", editor.refreshSeconds)
        refreshStepper.doubleValue = editor.refreshSeconds
    }

    @objc private func refreshChanged() {
        editor.setRefreshSeconds(max(1, Double(refreshField.stringValue) ?? editor.refreshSeconds))
        refreshStepper.doubleValue = editor.refreshSeconds
        refreshField.stringValue = String(format: "%g", editor.refreshSeconds)
        updateDirtyState()
    }

    @objc private func stepperChanged() {
        editor.setRefreshSeconds(max(1, refreshStepper.doubleValue))
        refreshField.stringValue = String(format: "%g", editor.refreshSeconds)
        updateDirtyState()
    }

    // MARK: - Dirty / Save

    private func updateDirtyState() {
        saveButton.isEnabled = editor.isDirty
    }

    @objc private func save() {
        let saved = editor.save()
        onChange?(saved)
        updateDirtyState()
    }

    // MARK: - Live field editing

    /// Build a `ServerConfig` from the form's current text (used by Test
    /// Connection so the user can test edits before saving). Independent of the
    /// table selection — it reads whatever is in the fields right now.
    private func currentServerFromFields() -> ServerConfig {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let path = rpcPathField.stringValue.trimmingCharacters(in: .whitespaces)
        return ServerConfig(
            name: name.isEmpty ? host : name,
            host: host,
            port: Int(portField.stringValue) ?? 9091,
            useHTTPS: httpsCheckbox.state == .on,
            rpcPath: path.isEmpty ? "/transmission/rpc" : path,
            username: usernameField.stringValue.isEmpty ? nil : usernameField.stringValue,
            password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue,
            pathMappings: PathMapping.parse(pathMappingsView.string))
    }

    /// Sync the selected server from the form's current text on every keystroke,
    /// so Save enables immediately (the field's target/action only fires on
    /// end-editing). Kept light: no trimming/uniqueness reset while typing — that
    /// normalization happens on end-editing in `serverFieldChanged`. Crucially it
    /// does NOT call `reloadData()` (which would drop the table selection mid-edit
    /// and break Test/Remove); it updates only the affected row label.
    private func liveSyncSelectedServer() {
        guard let i = selectedIndex else { return }
        // Take the raw fields as-is (no name normalization while typing); the
        // editor handles the currentServer-rename follow.
        var candidate = currentServerFromFields()
        candidate.name = nameField.stringValue   // keep raw (currentServerFromFields trims)
        editor.updateServer(at: i, to: candidate, normalizeName: false)
        updateRowLabel(at: i)
        reloadDefaultServerPopup()
        updateDirtyState()
    }

    /// Update one server row's displayed name in place, without `reloadData()`
    /// (which would reset the table selection).
    private func updateRowLabel(at index: Int) {
        guard let server = editor.server(at: index) else { return }
        if let cell = serverTable.view(atColumn: 0, row: index, makeIfNecessary: false)
            as? NSTableCellView {
            cell.textField?.stringValue = server.name
        }
    }

    // MARK: - Test Connection

    /// One candidate's probe outcome.
    private struct HostProbeResult {
        let server: ServerConfig
        let version: String?      // non-nil on success
        let error: Error?         // non-nil on failure
        var ok: Bool { version != nil }
    }

    @objc private func testConnection() {
        // Test exactly what's typed in the form right now, even if not yet saved.
        // The host field may list several candidates; probe EVERY one and report
        // which ones worked (not just the first), so the user can see the full
        // failover picture.
        let candidates = currentServerFromFields().connectionCandidates.filter { !$0.host.isEmpty }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enter a host to test"
            alert.informativeText = "Type a host name or IP address first, then try again."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        testButton.isEnabled = false
        testSpinner.startAnimation(nil)

        Task { [weak self] in
            let results = await Self.probeAll(candidates)
            guard let self else { return }
            self.testSpinner.stopAnimation(nil)
            self.testButton.isEnabled = self.selectedIndex != nil
            self.presentTestResults(results)
        }
    }

    /// Probe all candidates concurrently; results are returned in candidate order.
    private static func probeAll(_ candidates: [ServerConfig]) async -> [HostProbeResult] {
        await withTaskGroup(of: (Int, HostProbeResult).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    do {
                        let client = try TransmissionClient(server: candidate, timeout: 5)
                        let info = try await client.fetchSession()
                        return (index, HostProbeResult(server: candidate, version: info.version, error: nil))
                    } catch {
                        return (index, HostProbeResult(server: candidate, version: nil, error: error))
                    }
                }
            }
            var byIndex: [Int: HostProbeResult] = [:]
            for await (index, result) in group { byIndex[index] = result }
            return candidates.indices.compactMap { byIndex[$0] }
        }
    }

    private func endpointLabel(_ s: ServerConfig) -> String {
        "\(s.useHTTPS ? "https" : "http")://\(s.host):\(s.port)"
    }

    private func presentTestResults(_ results: [HostProbeResult]) {
        let okCount = results.filter(\.ok).count
        let alert = NSAlert()

        if results.count == 1 {
            // Single host: keep the focused success/failure message.
            let r = results[0]
            if let version = r.version {
                alert.alertStyle = .informational
                alert.messageText = "Connection succeeded"
                alert.informativeText = "Connected to \(endpointLabel(r.server)).\nTransmission \(version)."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Connection failed"
                alert.informativeText = r.error.map { ConnectionDiagnostics.message(for: $0, server: r.server) }
                    ?? "Could not reach the server."
            }
        } else {
            alert.alertStyle = okCount > 0 ? .informational : .warning
            alert.messageText = okCount > 0
                ? "\(okCount) of \(results.count) hosts responded"
                : "No hosts responded"
            // One line per candidate, in order. The app uses the first ✓ at runtime.
            alert.informativeText = results.map { r in
                if let version = r.version {
                    return "✓  \(endpointLabel(r.server)) — Transmission \(version)"
                } else {
                    return "✗  \(endpointLabel(r.server)) — \(Self.shortError(r.error))"
                }
            }.joined(separator: "\n")
        }
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    /// A terse failure reason for the per-host list.
    private static func shortError(_ error: Error?) -> String {
        guard let error else { return "no response" }
        switch error as? TransmissionError {
        case .authenticationFailed: return "auth failed (check username/password)"
        case .httpError(404): return "no RPC at that path (404)"
        case .httpError(let code): return "HTTP \(code)"
        case .connectionFailed: return "could not connect"
        case .invalidURL: return "invalid URL"
        case .rpcError(let m): return m
        case .decodingFailed: return "not a Transmission RPC endpoint"
        case .none: return error.localizedDescription
        }
    }
}

// MARK: - Live text editing

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as AnyObject) === refreshField {
            // Update the working copy live; don't rewrite the field text mid-type.
            if let value = Double(refreshField.stringValue) {
                editor.setRefreshSeconds(max(1, value))
                refreshStepper.doubleValue = editor.refreshSeconds
            }
            updateDirtyState()
        } else {
            liveSyncSelectedServer()
        }
    }
}

extension SettingsWindowController: NSTextViewDelegate {
    /// The multi-line path-mappings editor changed — sync it live like the text
    /// fields, so Save enables on each keystroke.
    func textDidChange(_ notification: Notification) {
        guard (notification.object as AnyObject) === pathMappingsView else { return }
        liveSyncSelectedServer()
    }
}

// MARK: - Server table data source / delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { editor.serverCount }

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
        cell.textField?.stringValue = editor.server(at: row)?.name ?? ""
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
        guard editor.isDirty else { return true }
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
            reset(to: editor.savedBaseline)
            return true
        default:                        // Cancel
            return false
        }
    }
}

/// An `NSTextView` that draws greyed-out placeholder text while it is empty —
/// `NSTextView` has no built-in placeholder the way `NSTextField` does.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
