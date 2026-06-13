import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        let config: AppConfig
        do {
            config = try ConfigLoader.load()
        } catch {
            presentStartupError(error)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        let controller = MainWindowController(config: config)
        windowController = controller
        controller.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc private func reloadConfig(_ sender: Any?) {
        do {
            let config = try ConfigLoader.load()
            windowController?.applyConfig(config)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not reload config"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func revealConfig(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigLoader.configURL])
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
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu.
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let reload = fileMenu.addItem(withTitle: "Reload Config",
                                      action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        reload.target = self
        let reveal = fileMenu.addItem(withTitle: "Reveal Config in Finder",
                                      action: #selector(revealConfig(_:)), keyEquivalent: "")
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

        NSApp.mainMenu = mainMenu
    }
}
