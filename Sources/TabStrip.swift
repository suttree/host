import Cocoa

/// A borderless, non-activating floating panel.
///
/// Non-activating matters: clicking a tab must not make Host the frontmost
/// application, because the whole point of the click is to make some *other*
/// application frontmost. .floating keeps the strip above the app window we just
/// raised, and .stationary + .canJoinAllSpaces stop it sliding around during
/// Mission Control transitions.
final class TabStripPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TabStripController: NSObject, NSWindowDelegate {
    private(set) var workspace: Workspace
    private let panel: TabStripPanel
    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    private(set) var activeIndex: Int?

    init(workspace: Workspace) {
        self.workspace = workspace
        self.panel = TabStripPanel(frame: workspace.stripFrame)
        super.init()

        let background = SunsetBarView()
        panel.contentView = background

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        panel.delegate = self
        isWorkspaceFront = true
        WindowManager.shared.onGeometryChange = { [weak self] bundleID, content in
            self?.followWindow(bundleID: bundleID, content: content)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidHide(_:)),
            name: NSWorkspace.didHideApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidUnhide(_:)),
            name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rebuild()
        panel.orderFrontRegardless()
    }

    // MARK: - UI

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        for (index, tab) in workspace.tabs.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.imagePosition = .imageLeading
            style(button, title: tab.name)
            if let icon = tab.icon {
                icon.size = NSSize(width: 16, height: 16)
                button.image = icon
            }
            button.toolTip = "\(tab.bundleIdentifier)   (control-\(index + 1))"

            // Right-click to remove. Deliberately not a hotkey and not an always
            // visible close button: tabs here are a persistent workspace rather
            // than transient documents, so removing one should take effort.
            let menu = NSMenu()
            let remove = NSMenuItem(title: "Remove \u{201C}\(tab.name)\u{201D}",
                                    action: #selector(removeTab(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            menu.addItem(remove)
            button.menu = menu

            stack.addArrangedSubview(button)
            buttons.append(button)
        }

        let add = NSButton(title: "", target: self, action: #selector(addClicked))
        style(add, title: "+")
        add.toolTip = "Add an application"
        stack.addArrangedSubview(add)

        highlight(activeIndex)
    }

    /// Black text on the sunset gradient, with a translucent white pill marking the
    /// active tab. The stock recessed bezel assumes a neutral background and turns
    /// muddy over orange.
    private func style(_ button: NSButton, title: String) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
    }

    private func highlight(_ index: Int?) {
        for (i, button) in buttons.enumerated() {
            button.layer?.backgroundColor = (i == index)
                ? NSColor(white: 1, alpha: 0.55).cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: - Actions

    @objc private func tabClicked(_ sender: NSButton) {
        select(index: sender.tag)
    }

    func select(index: Int) {
        guard index < workspace.tabs.count else { return }
        guard AXPermission.isTrusted else {
            AppDelegate.shared?.nagAboutPermission()
            return
        }
        let tab = workspace.tabs[index]
        activeIndex = index
        highlight(index)
        isWorkspaceFront = true
        panel.orderFrontRegardless()   // may have been hidden with the workspace

        // Hand over activation rights before asking. Cheap, main-thread, and works
        // whether or not the target app is running yet.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: tab.bundleIdentifier)
        }

        WindowManager.shared.place(bundleID: tab.bundleIdentifier, in: workspace.contentFrame) { result in
            if let error = result.error {
                Log.line("FAILED \(tab.name): \(error)")
                return
            }
            let drift = result.drift.map { String(format: "%.0fpt", $0) } ?? "unknown"
            Log.line(String(format: "%@ placed (launch %@, waited %.2fs, drift %@)",
                            tab.name, result.launched ? "yes" : "no", result.waitedForWindow, drift))
            Log.line("  requested(ax) \(NSStringFromRect(result.requested))")
            Log.line("  actual(ax)    \(NSStringFromRect(result.actual ?? .zero))")
            // Keep the strip above the window that was just raised.
            self.showStripIfAppropriate()

            // Did it actually come forward? Placement succeeding tells us nothing
            // about z-order, and that distinction is the whole bug.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
                let ok = front == tab.bundleIdentifier ? "ok" : "WRONG"
                Log.line("  frontmost after switch: \(front) [\(ok)]")
            }
        }
    }

    @objc private func addClicked() { addApplication() }

    func addApplication() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowedContentTypes = [.application]
        open.allowsMultipleSelection = false
        open.prompt = "Add Tab"
        guard open.runModal() == .OK, let url = open.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        addTab(name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: id)
    }

    /// Add an app and put it straight into the workspace.
    ///
    /// Selecting it is the point: a new tab that sits there at whatever size and
    /// position the app last happened to use, until you click it, reads as the add
    /// having not worked.
    func addTab(name: String, bundleIdentifier id: String) {
        // Tabs are keyed by bundle id throughout -- bound window, geometry
        // suppression, hotkey index -- so two tabs for one app would fight over
        // the same state. Adding a duplicate selects the existing tab instead.
        if let existing = workspace.tabs.firstIndex(where: { $0.bundleIdentifier == id }) {
            Log.line("\(name) is already a tab; selecting it")
            select(index: existing)
            return
        }

        workspace.tabs.append(AppTab(name: name, bundleIdentifier: id))
        Store.save(workspace)
        rebuild()
        AppDelegate.shared?.registerHotKeys()
        Log.line("added \(name) (\(id))")
        select(index: workspace.tabs.count - 1)
    }

    @objc private func removeTab(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < workspace.tabs.count else { return }
        let removed = workspace.tabs.remove(at: index)

        // The app itself is left alone -- still running, window still where we
        // put it. Removing a tab is forgetting about an app, not closing it.
        WindowManager.shared.forget(bundleID: removed.bundleIdentifier)

        if let active = activeIndex {
            if active == index { activeIndex = nil }
            else if active > index { activeIndex = active - 1 }
        }
        Store.save(workspace)
        rebuild()
        AppDelegate.shared?.registerHotKeys()
        Log.line("removed \(removed.name) -- the app is still running, window left in place")
    }

    // MARK: - Moving the workspace

    func windowDidMove(_ notification: Notification) {
        guard !isSyncingStrip else { return }
        // The strip is the handle for the whole workspace: dragging it drags the
        // app window with it.
        let strip = panel.frame
        workspace.frame = CGRect(x: strip.minX, y: strip.maxY - workspace.frame.height,
                                 width: workspace.frame.width, height: workspace.frame.height)
        Store.save(workspace)
        if let index = activeIndex { select(index: index) }
    }

    /// Render the strip exactly as drawn, for checking the look without a screen
    /// recording permission.
    func writeBarPreview(to path: String) {
        guard let view = panel.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Log.line("wrote bar preview to \(path)")
    }

    func raiseStrip() {
        isWorkspaceFront = true
        panel.orderFrontRegardless()
    }

    // MARK: - Staying out of the way

    /// The strip floats above normal windows so it can sit on top of the app it is
    /// hosting. That would also put it on top of every unrelated window on the
    /// screen, so instead of lowering its level -- which would bury it under the
    /// very window it belongs to -- it is shown only while the workspace is the
    /// thing you are actually looking at.
    private var isWorkspaceFront = true

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let id = app.bundleIdentifier
        let ours = id == Bundle.main.bundleIdentifier
            || workspace.tabs.contains { $0.bundleIdentifier == id }
        guard ours != isWorkspaceFront else { return }
        isWorkspaceFront = ours
        if ours {
            panel.orderFrontRegardless()
            Log.line("workspace is front (\(id ?? "?")); strip visible=\(panel.isVisible)")
        } else {
            panel.orderOut(nil)
            Log.line("\(id ?? "another app") is front; strip visible=\(panel.isVisible)")
        }
    }

    /// Order the strip front only if the workspace is what is in front.
    private func showStripIfAppropriate() {
        guard isWorkspaceFront else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Hiding as one unit

    /// Set while we are hiding the other apps ourselves, so their own hide
    /// notifications do not re-enter this and start a cascade.
    private var isBulkHiding = false

    @objc private func appDidHide(_ note: Notification) {
        guard !isBulkHiding,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              workspace.tabs.contains(where: { $0.bundleIdentifier == id }) else { return }

        isBulkHiding = true
        Log.line("\(id) hidden; hiding the rest of the workspace")
        for tab in workspace.tabs where tab.bundleIdentifier != id {
            WindowManager.runningApp(tab.bundleIdentifier)?.hide()
        }
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.isBulkHiding = false }
    }

    @objc private func appDidUnhide(_ note: Notification) {
        guard !isBulkHiding,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              let index = workspace.tabs.firstIndex(where: { $0.bundleIdentifier == id }) else { return }
        // Only the strip comes back, not every app: unhiding one tab should not
        // drag the other four onto the screen with it.
        Log.line("\(id) unhidden; restoring the strip")
        activeIndex = index
        highlight(index)
        showStripIfAppropriate()
    }

    // MARK: - Following the app window

    /// Set while we reposition the panel ourselves, so the windowDidMove handler
    /// does not read our own move as a user drag and push the window back.
    private var isSyncingStrip = false

    /// The user resized or moved the app window by its own edges. Re-derive the
    /// workspace from the window rather than the other way round, so the strip
    /// keeps sitting exactly on top of it at exactly its width.
    func followWindow(bundleID: String, content: CGRect) {
        guard let active = activeIndex, active < workspace.tabs.count,
              workspace.tabs[active].bundleIdentifier == bundleID else { return }
        guard !isSyncingStrip else { return }

        workspace.frame = CGRect(x: content.minX, y: content.minY,
                                 width: content.width,
                                 height: content.height + workspace.stripHeight)

        var strip = workspace.stripFrame
        // A window dragged to the top of the display would push the strip up
        // under the menu bar, so pin it and let it overlap the window instead.
        if let visible = NSScreen.main?.visibleFrame, strip.maxY > visible.maxY {
            strip.origin.y = visible.maxY - strip.height
        }
        guard !strip.equalTo(panel.frame) else { return }

        isSyncingStrip = true
        panel.setFrame(strip, display: true)
        DispatchQueue.main.async { self.isSyncingStrip = false }
        Store.save(workspace)
    }
}
