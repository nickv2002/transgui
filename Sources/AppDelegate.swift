import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// The Server menu's submenu, rebuilt on demand from the configured servers.
    private let serverMenu = NSMenu(title: "Server")
    /// The native Settings window, created lazily on first open.
    private var settingsController: SettingsWindowController?
    /// The live app config (servers + poll interval), kept in sync with the
    /// preferences store and the Settings window.
    private var config = AppConfig.default

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        do {
            config = try PreferencesStore.load()
        } catch {
            presentStartupError(error)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let controller = MainWindowController(config: config)
        windowController = controller
        controller.showWindow(nil)
        rebuildServerMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Persist the window frame on quit. AppKit's automatic frame autosave doesn't
    /// reliably flush under this app's manual `main.swift` run loop, so save it
    /// explicitly here (paired with `setFrameUsingName` restore on launch).
    func applicationWillTerminate(_ notification: Notification) {
        windowController?.window?.saveFrame(usingName: "MainWindow")
    }

    /// Dock drop / "Open With" of `.torrent` files.
    func application(_ application: NSApplication, open urls: [URL]) {
        windowController?.addFiles(urls)
    }

    // MARK: - Add menu forwarding

    @objc private func addTorrentFile(_ sender: Any?) { windowController?.addFile(sender) }
    @objc private func addTorrentLink(_ sender: Any?) { windowController?.addLink(sender) }

    // MARK: - Menu actions

    /// Open (or focus) the native Settings window. Edits are persisted to the
    /// preferences store and applied to the live connection immediately.
    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            let controller = SettingsWindowController(config: config)
            controller.onChange = { [weak self] updated in
                guard let self else { return }
                self.config = updated
                do {
                    try PreferencesStore.save(updated)
                } catch {
                    NSLog("Failed to save preferences: \(error.localizedDescription)")
                }
                self.windowController?.applyConfig(updated)
                self.rebuildServerMenu()
            }
            settingsController = controller
        } else {
            // Reopened: reflect the latest saved config, discarding any prior edits.
            settingsController?.reset(to: config)
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private enum GitHub {
        static let slug = "nickv2002/Transmission-Remote-MacOS"
        static let repoURL      = URL(string: "https://github.com/\(slug)")!
        static let releasesURL  = URL(string: "https://github.com/\(slug)/releases")!
        static let apiLatestURL = URL(string: "https://api.github.com/repos/\(slug)/releases/latest")!
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let linkStr = NSMutableAttributedString(string: "GitHub Project")
        let range = NSRange(location: 0, length: linkStr.length)
        linkStr.addAttribute(.link, value: GitHub.repoURL, range: range)
        linkStr.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: range)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: linkStr])
    }

    @objc private func checkForUpdate(_ sender: Any?) {
        Task { @MainActor in
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            do {
                var req = URLRequest(url: GitHub.apiLatestURL)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    throw URLError(.cannotParseResponse)
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let alert = NSAlert()
                if latest.localizedStandardCompare(current) == .orderedDescending {
                    alert.messageText = "Update Available"
                    alert.informativeText = "Version \(latest) is available (you have \(current))."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "OK")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(GitHub.releasesURL)
                    }
                } else {
                    alert.messageText = "Up to Date"
                    alert.informativeText = "You're running the latest release (\(current))."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Update Check Failed"
                alert.informativeText = "Could not check for updates: \(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func revealPreferences(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([PreferencesStore.storeURL])
    }

    @objc private func findInList(_ sender: Any?) {
        windowController?.focusSearch()
    }

    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not start"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        // App menu.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        about.target = self
        let checkUpdate = appMenu.addItem(withTitle: "Check for Update…",
                                          action: #selector(checkForUpdate(_:)), keyEquivalent: "")
        checkUpdate.target = self
        appMenu.addItem(.separator())
        // Standard "Settings…" (⌘,) opens the native preferences window.
        let settings = appMenu.addItem(withTitle: "Settings…",
                        action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        // Standard Hide / Hide Others / Show All (⌘H, ⌥⌘H). Without these explicit
        // items the key equivalents are unbound and ⌘H does nothing.
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu.
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let addFile = fileMenu.addItem(withTitle: "Add Torrent File…",
                                       action: #selector(addTorrentFile(_:)), keyEquivalent: "o")
        addFile.target = self
        let addLink = fileMenu.addItem(withTitle: "Add Magnet or URL…",
                                       action: #selector(addTorrentLink(_:)), keyEquivalent: "l")
        addLink.target = self
        fileMenu.addItem(.separator())
        // Standard Close (⌘W) — routes via the responder chain to the key window,
        // so it closes the Settings window (and any other) with a nil target.
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let reveal = fileMenu.addItem(withTitle: "Reveal Preferences in Finder",
                                      action: #selector(revealPreferences(_:)), keyEquivalent: "")
        reveal.target = self
        fileMenuItem.submenu = fileMenu

        // Edit menu (gives text fields standard cut/copy/paste + select all).
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find", action: #selector(findInList(_:)), keyEquivalent: "f")
        find.target = self
        editMenuItem.submenu = editMenu

        // Torrent menu — mirrors the right-click context menu. Targets are nil so
        // actions route through the first-responder chain to MainWindowController.
        let torrentMenuItem = NSMenuItem()
        mainMenu.addItem(torrentMenuItem)
        let torrentMenu = NSMenu(title: "Torrent")

        torrentMenu.addItem(withTitle: "Start",
                            action: #selector(MainWindowController.startSelected(_:)),
                            keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command]
        torrentMenu.addItem(withTitle: "Stop",
                            action: #selector(MainWindowController.stopSelected(_:)),
                            keyEquivalent: ".")
            .keyEquivalentModifierMask = [.command]
        torrentMenu.addItem(withTitle: "Force Start",
                            action: #selector(MainWindowController.forceStartSelected(_:)),
                            keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .option]

        torrentMenu.addItem(.separator())

        torrentMenu.addItem(withTitle: "Verify",
                            action: #selector(MainWindowController.verifySelected(_:)),
                            keyEquivalent: "")

        let queueSub = NSMenu(title: "Queue")
        for (title, tag) in [("Move to Top", 0), ("Move Up", 1),
                              ("Move Down", 2), ("Move to Bottom", 3)] {
            queueSub.addItem(withTitle: title,
                             action: #selector(MainWindowController.queueMoveSelected(_:)),
                             keyEquivalent: "").tag = tag
        }
        torrentMenu.addItem(withTitle: "Queue", action: nil, keyEquivalent: "")
            .submenu = queueSub

        let prioritySub = NSMenu(title: "Priority")
        for p in [BandwidthPriority.high, .normal, .low] {
            prioritySub.addItem(withTitle: p.displayName,
                                action: #selector(MainWindowController.setPrioritySelected(_:)),
                                keyEquivalent: "").tag = p.rawValue
        }
        torrentMenu.addItem(withTitle: "Priority", action: nil, keyEquivalent: "")
            .submenu = prioritySub

        torrentMenu.addItem(.separator())

        torrentMenu.addItem(withTitle: "Reveal in Finder",
                            action: #selector(MainWindowController.revealInFinderSelected(_:)),
                            keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .shift]
        torrentMenu.addItem(withTitle: "Open",
                            action: #selector(MainWindowController.openSelected(_:)),
                            keyEquivalent: "\r")
            .keyEquivalentModifierMask = [.command]

        torrentMenu.addItem(.separator())

        torrentMenu.addItem(withTitle: "Rename…",
                            action: #selector(MainWindowController.renameSelected(_:)),
                            keyEquivalent: "\r")
            .keyEquivalentModifierMask = []
        torrentMenu.addItem(withTitle: "Move…",
                            action: #selector(MainWindowController.moveSelected(_:)),
                            keyEquivalent: "")

        torrentMenu.addItem(.separator())

        // "Remove Torrent" needs no confirmation; "Remove + Data…" does — Option skips it.
        torrentMenu.addItem(withTitle: "Remove Torrent",
                            action: #selector(MainWindowController.removeTorrentDirectly(_:)),
                            keyEquivalent: "\u{08}")
        do {
            let item = torrentMenu.addItem(withTitle: "Remove Torrent + Data…",
                                           action: #selector(MainWindowController.removeTorrentWithDataConfirm(_:)),
                                           keyEquivalent: "\u{08}")
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        do {
            let alt = torrentMenu.addItem(withTitle: "Remove + Data Without Confirmation",
                                          action: #selector(MainWindowController.removeTorrentWithDataDirectly(_:)),
                                          keyEquivalent: "\u{08}")
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.command, .shift, .option]
        }

        torrentMenuItem.submenu = torrentMenu

        // Server menu — lists the configured servers; the active one is checked.
        let serverMenuItem = NSMenuItem()
        mainMenu.addItem(serverMenuItem)
        serverMenu.delegate = self
        serverMenu.autoenablesItems = false
        serverMenuItem.submenu = serverMenu

        NSApp.mainMenu = mainMenu
    }

    /// Rebuild the Server submenu from the controller's configured servers, with a
    /// checkmark on the active one.
    private func rebuildServerMenu() {
        serverMenu.removeAllItems()
        guard let controller = windowController else { return }
        let active = controller.refresh.currentServerName
        for name in controller.refresh.availableServerNames {
            let item = serverMenu.addItem(withTitle: name,
                                          action: #selector(selectServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == active) ? .on : .off
        }
        serverMenu.addItem(.separator())
        let refreshItem = serverMenu.addItem(withTitle: "Refresh Now",
                                              action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true
    }

    @objc private func refreshNow(_ sender: Any?) {
        windowController?.refresh.refreshNow()
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        windowController?.selectServer(name)
        rebuildServerMenu()
    }
}

// MARK: - Server menu refresh

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === serverMenu { rebuildServerMenu() }
    }
}
