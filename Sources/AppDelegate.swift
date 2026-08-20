import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    private var strip: TabStripController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Log.startFile()

        buildMainMenu()

        let workspace = Store.load()
        strip = TabStripController(workspace: workspace)
        Store.save(strip.workspace)

        registerHotKeys()

        Log.line("host up. tabs: \(strip.workspace.tabs.map(\.name).joined(separator: ", "))")
        Log.line("workspace rect \(NSStringFromRect(strip.workspace.frame))")
        Log.line("accessibility trusted: \(AXPermission.isTrusted)")

        if !AXPermission.isTrusted {
            AXPermission.requestIfNeeded()
            nagAboutPermission()
        } else {
            diagnose()
            // `open -a Host --args --cycle` walks every tab once and logs what
            // actually ended up frontmost, so a switch can be verified without a
            // human clicking.
            if CommandLine.arguments.contains("--cycle") { cycleAllTabs() }
            if CommandLine.arguments.contains("--resize-test") { resizeTest() }
            if CommandLine.arguments.contains("--hide-test") { hideTest() }
            // `--move-tab 4 0` exercises the reorder model without a mouse.
            if let i = CommandLine.arguments.firstIndex(of: "--move-tab"),
               i + 2 < CommandLine.arguments.count,
               let from = Int(CommandLine.arguments[i + 1]),
               let to = Int(CommandLine.arguments[i + 2]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Log.line("before: \(self.strip.workspace.tabs.map(\.name).joined(separator: ", "))")
                    self.strip.moveTab(from: from, to: to)
                }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--bar-preview"),
               i + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.strip.writeBarPreview(to: path)
                }
            }
            // `open -a Host --args --add com.apple.TextEdit` exercises the add
            // path without driving the open panel.
            if let i = CommandLine.arguments.firstIndex(of: "--add"),
               i + 1 < CommandLine.arguments.count {
                let id = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
                        .deletingPathExtension().lastPathComponent ?? id
                    self.strip.addTab(name: name, bundleIdentifier: id)
                }
            }
        }
    }

    func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        for index in strip.workspace.tabs.indices {
            HotKeyCenter.shared.registerControlDigit(index: index) { [weak self] in
                self?.strip.select(index: index)
            }
        }
        rebuildTabsMenu()
        Log.line("hotkeys: control-1 .. control-\(strip.workspace.tabs.count)")
    }

    /// Clicking the Dock icon brings the whole workspace back, not just the strip.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        strip?.restoreWorkspace()
        return true
    }

    // MARK: - Menu
    //
    // A .regular app owns the menu bar while it is frontmost, so it needs a real
    // one. Note the tab shortcuts are listed for discoverability only: menu key
    // equivalents fire when Host is active, and Host is almost never active. The
    // Carbon hotkeys in HotKeyCenter are what actually do the work.

    private var tabsMenu: NSMenu?

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Host", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Host", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let tabsItem = NSMenuItem()
        let tabs = NSMenu(title: "Tabs")
        tabsItem.submenu = tabs
        mainMenu.addItem(tabsItem)
        tabsMenu = tabs

        NSApp.mainMenu = mainMenu
        rebuildTabsMenu()
    }

    private func rebuildTabsMenu() {
        guard let menu = tabsMenu, let strip else { return }
        menu.removeAllItems()
        for (index, tab) in strip.workspace.tabs.enumerated() where index < 9 {
            let item = NSMenuItem(title: tab.name, action: #selector(tabMenuItem(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.control]
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Application…", action: #selector(addApplication), keyEquivalent: "t")
        add.target = self
        menu.addItem(add)
        let test = NSMenuItem(title: "Run Self-test", action: #selector(runSelfTest), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let log = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let diag = NSMenuItem(title: "Diagnose Tabs", action: #selector(diagnoseTabs), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let ax = NSMenuItem(title: "Accessibility Settings…", action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
    }

    @objc private func tabMenuItem(_ sender: NSMenuItem) { strip.select(index: sender.tag) }
    @objc private func addApplication() { strip.addApplication() }
    @objc private func runSelfTest() { SelfTest.run(controller: strip) }
    @objc private func showLog() { LogWindow.shared.show() }
    @objc private func openAXSettings() { AXPermission.openSettings() }
    @objc private func diagnoseTabs() { LogWindow.shared.show(); diagnose() }

    /// Read-only. Reports what each configured app exposes over AX without
    /// launching anything or moving a single window.
    func diagnose() {
        let tabs = strip.workspace.tabs
        DispatchQueue.global(qos: .userInitiated).async {
            var lines = ["--- diagnostics ---"]
            for tab in tabs { lines.append(contentsOf: axDescribe(tab.bundleIdentifier)) }
            lines.append("--- end diagnostics ---")
            for line in lines { Log.line(line) }
        }
    }

    private func cycleAllTabs() {
        Log.line("--- cycling all tabs ---")
        for (index, tab) in strip.workspace.tabs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 2.0) {
                Log.line("cycle -> \(tab.name)")
                self.strip.select(index: index)
            }
        }
    }

    /// Reproduces "resize one window, switch tab, the next window does not match".
    /// Placing Byword at an odd size fires exactly the same AX notification a user
    /// drag would, so this exercises the real path.
    private func resizeTest() {
        guard strip.workspace.tabs.count >= 2 else { return }
        let odd = CGRect(x: 140, y: 200, width: 860, height: 520)
        Log.line("--- resize test ---")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.strip.select(index: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Log.line("forcing \(self.strip.workspace.tabs[0].name) to \(NSStringFromRect(odd))")
            WindowManager.shared.place(bundleID: self.strip.workspace.tabs[0].bundleIdentifier, in: odd) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            Log.line("workspace after resize: \(NSStringFromRect(self.strip.workspace.frame))")
            Log.line("content after resize:   \(NSStringFromRect(self.strip.workspace.contentFrame))")
        }
        for (index, tab) in strip.workspace.tabs.enumerated() where index > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0 + Double(index) * 2.5) {
                Log.line("switching to \(tab.name); workspace content is now \(NSStringFromRect(self.strip.workspace.contentFrame))")
                self.strip.select(index: index)
            }
        }
    }

    /// Hides the first tab's app the same way a user pressing command-H would, then
    /// reports which of the others followed it down.
    private func hideTest() {
        guard let first = strip.workspace.tabs.first else { return }
        Log.line("--- hide test ---")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.strip.select(index: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Log.line("hiding \(first.name)")
            WindowManager.runningApp(first.bundleIdentifier)?.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            for tab in self.strip.workspace.tabs {
                let app = WindowManager.runningApp(tab.bundleIdentifier)
                let state = app == nil ? "not running" : (app!.isHidden ? "hidden" : "STILL VISIBLE")
                Log.line("  \(tab.name): \(state)")
            }
            Log.line("--- hide test done ---")
        }
    }

    func nagAboutPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Host needs Accessibility permission"
        alert.informativeText = """
        Moving another application's windows requires it.

        System Settings › Privacy & Security › Accessibility, then add Host \
        and switch it on.

        If Host is already listed and ticked but nothing moves, the build was \
        re-signed since you granted it: remove the entry with the minus button and \
        add it again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            AXPermission.openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        Store.save(strip.workspace)
    }
}
