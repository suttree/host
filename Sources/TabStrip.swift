import Cocoa

/// A borderless, non-activating floating panel.
///
/// Non-activating matters: clicking a tab must not make Host the frontmost
/// application, because the whole point of the click is to make some *other*
/// application frontmost. .floating keeps the strip above the app window we just
/// raised. .managed lets Mission Control sweep it aside with the hosted window.
///
/// Deliberately not .canJoinAllSpaces. A full-screen window gets a Space of its
/// own, and that flag makes the strip follow it there -- so it sits on top of
/// full-screen video. Without it the strip stays on the Space it belongs to,
/// which is also where the hosted windows are.
final class TabStripPanel: NSPanel {
    init(frame: CGRect, acceptsKeyboardInput: Bool = false) {
        super.init(contentRect: frame,
                   styleMask: acceptsKeyboardInput ? [.borderless] : [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.managed, .fullScreenNone]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The tab strip's background, in whatever theme is current.
///
/// The palette tiles here rather than being fitted to the shape once, as it is on
/// the icon: the strip is long and short, so one pass would stretch each band into
/// an unreadable smear.
final class ThemeBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.current.fill(Theme.roundedBarPath(bounds, radius: 10), stripeWidth: 34)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppDelegate.shared?.applyApplicationIcon(for: effectiveAppearance)
    }
}

private final class RunningAppSearchField: NSSearchField {
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

final class TabStripController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    private(set) var workspace: Workspace
    private let panel: TabStripPanel
    private let stack = NSStackView()
    private let cog = NSButton()
    private var buttons: [TabButton] = []
    private var recentAppIDs: [String] = []
    private var runningAppCycle = RunningAppCycle()
    private var commandTabPreview = false
    private var searchField: RunningAppSearchField!
    private var searchQuery = ""
    private let searchPanel = TabStripPanel(frame: .zero, acceptsKeyboardInput: true)
    private(set) var activeIndex: Int?

    init(workspace: Workspace) {
        self.workspace = workspace
        self.panel = TabStripPanel(frame: workspace.stripFrame)
        super.init()

        let background = ThemeBarView()
        panel.contentView = background

        // Pinned to the trailing edge rather than added to the stack, so it stays
        // at the far right however many tabs there are.
        cog.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
        cog.imagePosition = .imageOnly
        cog.isBordered = false
        cog.wantsLayer = true
        cog.layer?.cornerRadius = 8
        cog.target = self
        cog.action = #selector(cogClicked)
        cog.toolTip = "Tab bar theme"
        cog.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(cog)
        NSLayoutConstraint.activate([
            cog.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            cog.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cog.widthAnchor.constraint(equalToConstant: 30),
            cog.heightAnchor.constraint(equalToConstant: 26),
        ])

        searchField = RunningAppSearchField()
        searchField.placeholderString = ""
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14, weight: .medium)
        searchField.setAccessibilityLabel("Find an app")
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        // NSSearchField sends its action after typing pauses. Selection must
        // happen only through the Enter command handled by the delegate.
        searchField.target = nil
        searchField.action = nil
        searchField.delegate = self
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onCancel = { [weak self] in self?.closeRunningAppSearch() }
        // A compact query pill keeps typed text visible without a launcher card.
        let searchContent = NSView()
        searchContent.wantsLayer = true
        searchContent.layer?.cornerRadius = 14
        searchContent.layer?.masksToBounds = true
        searchPanel.contentView = searchContent
        searchPanel.isReleasedWhenClosed = false
        searchPanel.hasShadow = false
        searchContent.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchContent.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: searchContent.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchContent.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 20),
        ])

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -52),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        panel.delegate = self
        isWorkspaceFront = false
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        recentAppIDs = initialRunningApps().compactMap(\.bundleIdentifier)
        rebuild()
        geometryPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in self?.refreshActiveGeometry()
        }
    }

    // MARK: - UI

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        let runningApps = orderedRunningApps()
        let labelLimit = labelLimit(for: runningApps)
        let labelledIDs = labelledRunningAppIDs(order: recentAppIDs, limit: labelLimit)

        var entries = runningApps.compactMap { app -> (id: String, name: String, icon: NSImage?)? in
            guard let id = app.bundleIdentifier else { return nil }
            return (id, app.localizedName ?? id, app.icon)
        }
        if !searchField.isHidden {
            let runningIDs = Set(entries.map(\.id))
            entries += workspace.tabs.filter { !runningIDs.contains($0.bundleIdentifier) }
                .map { ($0.bundleIdentifier, $0.name, $0.icon) }
        }
        for app in entries {
            let id = app.id
            let name = app.name
            let workspaceIndex = workspace.tabs.firstIndex { $0.bundleIdentifier == id }
            let button = TabButton(title: "", target: self, action: #selector(tabClicked(_:)))
            button.bundleIdentifier = id
            button.tabName = name
            button.tabIcon = app.icon
            button.workspaceIndex = workspaceIndex
            button.showsLabel = labelledIDs.contains(id)
            if button.showsLabel {
                style(button, title: name)
            } else {
                styleRunningApp(button)
            }
            button.toolTip = name

            // Every running app gets a context menu. Unhosted apps can be added;
            // hosted apps can be detached, attached, or removed.
            let menu = NSMenu()
            if let workspaceIndex {
                // Right-click removes the app from the managed workspace. It stays
                // in this running-app list until the app itself quits.
                let remove = NSMenuItem(title: "Stop Hosting \u{201C}\(name)\u{201D}",
                                        action: #selector(removeTab(_:)), keyEquivalent: "")
                remove.target = self
                remove.tag = workspaceIndex
                menu.addItem(remove)
                let detach = NSMenuItem(title: workspace.tabs[workspaceIndex].isDetached ? "Attach to Workspace" : "Detach from Workspace",
                                        action: #selector(toggleDetached(_:)), keyEquivalent: "")
                detach.target = self
                detach.tag = workspaceIndex
                menu.addItem(detach)
            } else {
                let add = NSMenuItem(title: "Add to Workspace",
                                     action: #selector(addRunningApp(_:)), keyEquivalent: "")
                add.target = self
                add.representedObject = id
                menu.addItem(add)
            }
            button.menu = menu

            stack.addArrangedSubview(button)
            buttons.append(button)
        }

        let add = symbolButton("plus", tooltip: "Add an application",
                               action: #selector(addClicked))
        stack.addArrangedSubview(add)

        highlight(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        cog.layer?.backgroundColor = Theme.current.chip.withAlphaComponent(0.55).cgColor
        cog.contentTintColor = Theme.current.text
    }

    /// Labels are useful when there is room, but icons keep the strip usable at
    /// narrow window widths. Estimate each button's width and spend the available
    /// space on the most-recently-used labels first.
    private func labelLimit(for apps: [NSRunningApplication]) -> Int {
        let available = max(120, panel.contentView?.bounds.width ?? panel.frame.width) - 84
        let maximum = min(workspace.tabs.count, apps.count)
        let labelledIDs = recentAppIDs.prefix(maximum)
        var limit = maximum

        while limit > 0 {
            let width = apps.reduce(CGFloat(0)) { total, app in
                guard let id = app.bundleIdentifier else { return total }
                if labelledIDs.prefix(limit).contains(id) {
                    let name = app.localizedName ?? id
                    return total + min(220, CGFloat(name.count) * 7.2 + 47)
                }
                return total + 30
            } + CGFloat(max(0, apps.count - 1)) * stack.spacing + 30
            if width <= available { break }
            limit -= 1
        }
        return limit
    }

    func toggleRunningAppSearch() {
        if searchField.isHidden {
            resumeAfterHide()
            searchQuery = ""
            searchField.stringValue = ""
            searchField.isHidden = false
            panel.level = .floating
            let searchWidth = min(180, panel.frame.width - 24)
            searchPanel.setFrame(NSRect(x: panel.frame.midX - searchWidth / 2,
                                       y: panel.frame.minY - 34,
                                       width: searchWidth, height: 28), display: true)
            panel.addChildWindow(searchPanel, ordered: .above)
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            searchPanel.makeKeyAndOrderFront(nil)
            rebuild()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.searchField.isHidden else { return }
                self.searchPanel.makeKey()
                self.searchPanel.makeFirstResponder(self.searchField)
            }
        } else {
            closeRunningAppSearch()
        }
    }

    private func closeRunningAppSearch() {
        searchQuery = ""
        searchField.stringValue = ""
        searchField.resignFirstResponder()
        searchField.isHidden = true
        panel.removeChildWindow(searchPanel)
        searchPanel.orderOut(nil)
        panel.makeFirstResponder(nil)
        stack.isHidden = false
        cog.isHidden = false
        panel.orderFrontRegardless()
        rebuild()
    }

    private func searchSubmitted(_ sender: NSSearchField) {
        guard let app = buttons.first(where: { appSearchMatches(name: $0.tabName, query: sender.stringValue) }) else { return }
        let id = app.bundleIdentifier
        let name = app.tabName
        closeRunningAppSearch()
        selectRunningApp(bundleIdentifier: id, name: name)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        searchQuery = field.stringValue
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeRunningAppSearch()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchSubmitted(searchField)
            return true
        }
        return false
    }

    @objc private func cogClicked() {
        AppDelegate.shared?.showSettings()
    }

    /// Every tab sits on its own card, not just the active one.
    ///
    /// This is what lets the stripes be as bold as they like: the text never
    /// touches the background, so legibility stops depending on which band happens
    /// to pass behind a given tab. The stock recessed bezel is no use here -- it
    /// assumes a neutral background and turns muddy over anything coloured.
    /// A square card carrying a single symbol, for the controls that are not tabs.
    ///
    /// Drawn as an image rather than as a text title: a "+" set as text sits on its
    /// own glyph bearings, which are not symmetric, so it lands visibly off centre
    /// however the padding is tuned. An imageOnly button centres the symbol itself.
    private func symbolButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = Theme.current.chip.withAlphaComponent(0.55).cgColor
        button.contentTintColor = Theme.current.text
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func style(_ button: NSButton, title: String) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = Theme.current.chip.withAlphaComponent(0.55).cgColor
        button.imagePosition = .noImage
        button.attributedTitle = Self.tabTitle(title, icon: (button as? TabButton)?.tabIcon, active: false)
        button.sizeToFit()

        // Padding comes from an explicit width, not from spaces in the title: the
        // icon is drawn leading, so no amount of leading whitespace puts a gap
        // before it, and trailing whitespace gets trimmed during layout. Giving the
        // button a width and letting AppKit centre the icon and text inside it pads
        // both sides evenly.
        //
        // Measured against the bold face, which is the wider of the two the active
        // state uses. The card therefore neither clips when a tab becomes active nor
        // changes width and reflows the whole strip as you switch tabs.
        let icon = (button as? TabButton)?.tabIcon
        let extra = Self.tabTitle(title, icon: icon, active: true).size().width
                  - Self.tabTitle(title, icon: icon, active: false).size().width
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: ceil(button.intrinsicContentSize.width + extra + 15)),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Older MRU entries use the compact icon treatment from Command-Tab.
    private func styleRunningApp(_ button: TabButton) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = Theme.current.chip.cgColor
        button.image = (button.tabIcon?.copy() as? NSImage) ?? button.tabIcon
        button.image?.size = NSSize(width: 18, height: 18)
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Icon and name as one attributed string, with the icon as a text attachment.
    ///
    /// NSButton's own image-plus-title layout puts a gap between the two that it
    /// does not expose, and app icons carry their own transparent margin on top of
    /// it, so the two never looked evenly spaced. As an attachment the gap is just
    /// kerning, and is set to exactly what it should be.
    private static func tabTitle(_ name: String, icon: NSImage?, active: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: active ? .bold : .regular)
        let result = NSMutableAttributedString()

        if let icon {
            icon.size = NSSize(width: 16, height: 16)
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Centred on the font's cap height rather than sitting on the baseline.
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - 16) / 2, width: 16, height: 16)
            result.append(NSAttributedString(attachment: attachment))
            // An en space, which is half the point size, so 6pt at 12pt type.
            // Kerning is not honoured across an attachment in a button title, so
            // the gap has to be a character with a width of its own.
            result.append(NSAttributedString(string: "\u{2002}", attributes: [.font: font]))
        }

        result.append(NSAttributedString(string: name, attributes: [
            .foregroundColor: Theme.current.text,
            .font: font,
        ]))
        return result
    }

    /// The active tab is fully opaque. Inactive tabs fade as one unit so their
    /// icons, labels, and cards all sit behind the current app visually.
    private func applyChip(_ button: TabButton, active: Bool) {
        button.layer?.backgroundColor = Theme.current.chip.cgColor
        button.alphaValue = commandTabPreview ? (active ? 1 : 0.22) : (active ? 1 : 0.52)
        button.layer?.borderWidth = commandTabPreview && active ? 2 : 0
        button.layer?.borderColor = commandTabPreview && active
            ? NSColor.white.withAlphaComponent(0.9).cgColor : nil
        button.layer?.shadowColor = commandTabPreview && active ? NSColor.black.cgColor : nil
        button.layer?.shadowOpacity = commandTabPreview && active ? 0.45 : 0
        button.layer?.shadowRadius = commandTabPreview && active ? 8 : 0
        button.layer?.shadowOffset = .zero
        if button.showsLabel {
            button.attributedTitle = Self.tabTitle(button.tabName, icon: button.tabIcon, active: active)
        }
    }

    private func highlight(_ bundleIdentifier: String?) {
        let matches = buttons.filter { appSearchMatches(name: $0.tabName, query: searchQuery) }
        for button in buttons {
            let active = searchField.isHidden ? button.bundleIdentifier == bundleIdentifier
                : appSearchMatches(name: button.tabName, query: searchQuery)
            applyChip(button, active: active)
            if !searchField.isHidden, button === matches.first {
                button.layer?.borderWidth = 2
                button.layer?.borderColor = Theme.current.text.cgColor
            }
        }
        searchField.textColor = Theme.current.text
        searchPanel.contentView?.layer?.backgroundColor = Theme.current.chip.cgColor
        searchPanel.contentView?.layer?.borderColor = Theme.current.text.withAlphaComponent(0.2).cgColor
        searchPanel.contentView?.layer?.borderWidth = 1
        searchPanel.contentView?.needsDisplay = true
    }

    /// Repaint the strip after the theme changes. The buttons are rebuilt because
    /// their title colour is baked into an attributed string.
    func applyTheme() {
        panel.contentView?.needsDisplay = true
        rebuild()
    }

    // MARK: - Actions

    @objc private func tabClicked(_ sender: NSButton) {
        guard let button = sender as? TabButton else { return }
        if !searchField.isHidden { closeRunningAppSearch() }
        resetRunningAppCycle()
        selectRunningApp(bundleIdentifier: button.bundleIdentifier, name: button.tabName)
    }

    private func selectRunningApp(bundleIdentifier: String, name: String? = nil) {
        resumeAfterHide()
        updateStripLevel(for: bundleIdentifier)
        if WindowManager.runningApp(bundleIdentifier) == nil,
           !workspace.hosts(bundleIdentifier: bundleIdentifier),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let index = workspace.tabs.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            if workspace.tabs[index].isDetached {
                // Detached tabs are launcher entries only. Do not route through
                // select(), which changes workspace active state before it
                // foregrounds the app and can race an activation callback.
                WindowManager.shared.forget(bundleID: bundleIdentifier)
                highlight(bundleIdentifier)
                WindowManager.shared.foreground(bundleID: bundleIdentifier)
                return
            }
            select(index: index)
        } else {
            // A running app that is not in the workspace is not implicitly
            // hosted by clicking its header button. This is also the behavior
            // users expect after detaching an app: click to foreground it,
            // choose Add to Workspace explicitly when hosting is wanted.
            highlight(bundleIdentifier)
            WindowManager.shared.forget(bundleID: bundleIdentifier)
            WindowManager.shared.foreground(bundleID: bundleIdentifier)
            Log.line("foregrounded unhosted (bundleIdentifier) from running-app header")
        }
    }

    private func placeRunningApp(name: String, bundleIdentifier: String) {
        guard AXPermission.isTrusted else {
            AppDelegate.shared?.nagAboutPermission()
            return
        }
        guard WindowManager.runningApp(bundleIdentifier) != nil else {
            refreshRunningApps()
            return
        }
        highlight(bundleIdentifier)
        transientHostedBundleID = bundleIdentifier
        isWorkspaceFront = true
        panel.level = .floating
        panel.orderFrontRegardless()

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)
        }

        WindowManager.shared.place(bundleID: bundleIdentifier, in: workspace.contentFrame) { result in
            if let error = result.error {
                Log.line("FAILED \(name): \(error)")
                return
            }
            let drift = result.drift.map { String(format: "%.0fpt", $0) } ?? "unknown"
            Log.line(String(format: "%@ placed from running-app header (waited %.2fs, drift %@)",
                            name, result.waitedForWindow, drift))
            Log.line("  requested(ax) \(NSStringFromRect(result.requested))")
            Log.line("  actual(ax)    \(NSStringFromRect(result.actual ?? .zero))")
            self.showStripIfAppropriate()
        }
    }

    func select(index: Int) {
        guard index < workspace.tabs.count else { return }
        guard AXPermission.isTrusted else {
            AppDelegate.shared?.nagAboutPermission()
            return
        }
        let tab = workspace.tabs[index]
        activeIndex = index
        rememberActiveTab(index: index)
        highlight(tab.bundleIdentifier)
        isWorkspaceFront = true
        panel.level = .floating
        panel.orderFrontRegardless()   // may have been hidden with the workspace

        if tab.isDetached {
            updateStripLevel(for: tab.bundleIdentifier)
            // A detached tab is a launcher entry, not part of the workspace.
            // Drop any stale placement binding before foregrounding it so an
            // earlier AX callback cannot pull it back to the workspace frame.
            WindowManager.shared.forget(bundleID: tab.bundleIdentifier)
            WindowManager.shared.foreground(bundleID: tab.bundleIdentifier)
            return
        }

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

    func selectRelative(offset: Int) {
        previewRelative(offset: offset)
        commitRunningAppCycle()
    }

    func previewRelative(offset: Int) {
        resumeAfterHide()
        // Command-Tab can begin while another app is frontmost. Keep the
        // preview strip visible above that app without activating Host itself.
        panel.level = .floating
        panel.orderFrontRegardless()
        commandTabPreview = true
        let liveOrder = recentAppIDs.filter { WindowManager.runningApp($0) != nil }
        guard let bundleIdentifier = runningAppCycle.preview(
            liveOrder: liveOrder,
            current: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            offset: offset
        ) else { return }
        highlight(bundleIdentifier)
    }

    func commitRunningAppCycle() {
        guard let bundleIdentifier = runningAppCycle.commit() else { return }
        commandTabPreview = false
        selectRunningApp(bundleIdentifier: bundleIdentifier)
        highlight(bundleIdentifier)
    }

    private func resetRunningAppCycle() {
        runningAppCycle.reset()
    }

    @objc private func addClicked() { addApplication() }

    func addApplication() {
        AppDelegate.shared?.holdWorkspaceForOpenPanel()
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

        if transientHostedBundleID == removed.bundleIdentifier {
            transientHostedBundleID = nil
        }

        // The app itself is left alone -- still running, window still where we
        // put it. Removing a tab is forgetting about an app, not closing it.
        WindowManager.shared.forget(bundleID: removed.bundleIdentifier)

        if let active = activeIndex {
            if active == index {
                activeIndex = nil
                // Removing the app that was keeping the workspace frontmost
                // must also drop the panel out of the floating window level.
                // No application-activation notification is guaranteed here.
                isWorkspaceFront = false
                panel.level = .normal
            }
            else if active > index { activeIndex = active - 1 }
        }
        Store.save(workspace)
        rebuild()
        AppDelegate.shared?.registerHotKeys()
        Log.line("removed \(removed.name) -- the app is still running, window left in place")
    }

    @objc private func addRunningApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let app = WindowManager.runningApp(id) else { return }
        addTab(name: app.localizedName ?? id, bundleIdentifier: id)
    }

    @objc private func toggleDetached(_ sender: NSMenuItem) {
        guard workspace.tabs.indices.contains(sender.tag) else { return }
        workspace.tabs[sender.tag].isDetached.toggle()
        Store.save(workspace)
        rebuild()
        Log.line("\(workspace.tabs[sender.tag].name) " +
                 (workspace.tabs[sender.tag].isDetached ? "detached from" : "attached to") + " workspace")
    }

    // MARK: - Moving the workspace

    func windowDidMove(_ notification: Notification) {
        guard !isSyncingStrip else { return }
        // The strip is the handle for the whole workspace: dragging it drags the
        // app windows with it.
        let strip = panel.frame
        workspace.frame = CGRect(x: strip.minX, y: strip.maxY - workspace.frame.height,
                                 width: workspace.frame.width, height: workspace.frame.height)

        // snap rather than select: the window should follow the strip without the
        // app being activated on every mouse-move event of the drag.
        if let index = activeIndex {
            WindowManager.shared.snap(bundleID: workspace.tabs[index].bundleIdentifier,
                                      in: workspace.contentFrame, reason: "workspace moved")
        }
        syncEveryTabSoon()
    }

    private var syncWork: DispatchWorkItem?

    /// Bring every tab's window to the workspace, not just the one you can see.
    ///
    /// Placing lazily -- only on switching to a tab -- is fine until the workspace
    /// moves, at which point the other windows are left behind at the old position
    /// and stick out from under the active one. They cannot simply be left to
    /// correct themselves on the next switch, because they are visible now.
    ///
    /// Debounced, because during a drag this fires on every mouse-move event and
    /// nine windows cannot be moved at that rate. The disk write waits for the same
    /// reason.
    /// Move the strip as a user drag would, firing the same delegate callback.
    /// Lets the drag path be exercised without a hand on the trackpad.
    func nudge(dx: CGFloat, dy: CGFloat) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
    }

    /// Tidy every tab into the workspace now, without waiting for a drag to settle.
    func syncEveryTab() {
        syncWork?.cancel()
        let content = workspace.contentFrame
        for tab in workspace.tabs {
            guard !tab.isDetached else { continue }
            WindowManager.shared.snap(bundleID: tab.bundleIdentifier, in: content,
                                      reason: "workspace moved")
        }
        Log.line("synced \(workspace.tabs.count) windows to \(NSStringFromRect(content))")
    }

    private func syncEveryTabSoon() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let content = self.workspace.contentFrame
            for tab in self.workspace.tabs {
                guard !tab.isDetached else { continue }
                WindowManager.shared.snap(bundleID: tab.bundleIdentifier, in: content,
                                          reason: "workspace moved")
            }
            Store.save(self.workspace)
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
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

    /// Whether the strip is genuinely being displayed, as opposed to merely
    /// ordered in. isVisible stays true for a window sitting on an inactive Space,
    /// so it cannot answer "is this on top of the full-screen video".
    func isOnScreen() -> Bool {
        let number = CGWindowID(panel.windowNumber)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == number }
    }

    /// Put the active tab's window in or out of full screen, to check what the
    /// strip does around it.
    func setActiveTabFullScreen(_ wanted: Bool) {
        guard let index = activeIndex, index < workspace.tabs.count else { return }
        WindowManager.shared.setFullScreen(bundleID: workspace.tabs[index].bundleIdentifier,
                                           to: wanted)
    }

    func raiseStrip() {
        guard !workspaceHidden else { return }
        isWorkspaceFront = true
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    /// Bring the workspace back after it has been hidden: the strip and the tab
    /// that was active when it went away. Raising the strip alone leaves a bar
    /// floating over nothing.
    ///
    /// Only the active tab is unhidden, not all of them, for the same reason
    /// appDidUnhide does not: coming back to one tab should not haul the other
    /// four onto the screen with it.
    func restoreWorkspace() {
        guard !workspaceHidden, searchField.isHidden else { return }
        raiseStrip()
        guard let index = activeIndex ?? savedActiveTabIndex() else { return }
        Log.line("restoring workspace: strip + \(workspace.tabs[index].name)")
        select(index: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let states = self.workspace.tabs.map { tab -> String in
                guard let app = WindowManager.runningApp(tab.bundleIdentifier) else { return "\(tab.name)=off" }
                return "\(tab.name)=\(app.isHidden ? "hidden" : "shown")"
            }
            Log.line("  after restore: \(states.joined(separator: "  "))  strip=\(self.panel.isVisible)")
        }
    }

    func restoreLastActiveTab() {
        guard let index = savedActiveTabIndex() else {
            Log.line("startup restore skipped: no tabs")
            return
        }
        Log.line("startup restore: \(workspace.tabs[index].name)")
        select(index: index)
    }

    private static let activeTabKey = "HostActiveTabBundleIdentifier"

    private func savedActiveTabIndex() -> Int? {
        restoredTabIndex(bundleIDs: workspace.tabs.map(\.bundleIdentifier),
                         lastActiveBundleID: UserDefaults.standard.string(forKey: Self.activeTabKey))
    }

    private func rememberActiveTab(index: Int) {
        guard workspace.tabs.indices.contains(index) else { return }
        UserDefaults.standard.set(workspace.tabs[index].bundleIdentifier, forKey: Self.activeTabKey)
    }

    // MARK: - Running applications

    /// Command-Tab includes regular applications, including hidden ones. Helper,
    /// accessory, and background processes do not belong in the header.
    private func eligibleRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
    }

    /// Seed the first MRU order from visible window z-order. macOS does not expose
    /// Command-Tab's stored order, so this is the closest public starting point.
    private func initialRunningApps() -> [NSRunningApplication] {
        let apps = eligibleRunningApps()
        let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        var ordered: [NSRunningApplication] = []
        var seen = Set<pid_t>()
        for window in windows {
            guard let number = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(number.int32Value)
            if let app = byPID[pid], seen.insert(pid).inserted { ordered.append(app) }
        }
        ordered.append(contentsOf: apps.filter { seen.insert($0.processIdentifier).inserted })
        return ordered
    }

    private func orderedRunningApps() -> [NSRunningApplication] {
        let apps = eligibleRunningApps()
        let byID = Dictionary(apps.compactMap { app in
            app.bundleIdentifier.map { ($0, app) }
        }, uniquingKeysWith: { first, _ in first })
        recentAppIDs = runningAppOrder(eligible: apps.compactMap(\.bundleIdentifier),
                                       previous: recentAppIDs)
        return recentAppIDs.compactMap { byID[$0] }
    }

    private func refreshRunningApps(promoting bundleIdentifier: String? = nil) {
        let eligible = eligibleRunningApps().compactMap(\.bundleIdentifier)
        let updated = runningAppOrder(eligible: eligible, previous: recentAppIDs,
                                      activated: bundleIdentifier)
        guard updated != recentAppIDs else {
            highlight(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            return
        }
        recentAppIDs = updated
        rebuild()
    }

    // MARK: - Quitting

    /// A hosted app can quit without removing its tab. Its bundle ID remains the
    /// attachment point, so the next launch can restore the app to the workspace.
    @objc private func appDidTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier else { return }
        refreshRunningApps()
        guard workspace.tabs.contains(where: { $0.bundleIdentifier == id }) else { return }
        WindowManager.shared.forget(bundleID: id)
        Log.line("\(id) quit; keeping its tab for automatic reattachment")
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier else { return }
        refreshRunningApps()
        guard let tab = workspace.tabs.first(where: { $0.bundleIdentifier == id }) else { return }
        Log.line("\(tab.name) relaunched; reattaching to workspace")
        guard !tab.isDetached else { return }
        WindowManager.shared.snap(bundleID: id, in: workspace.contentFrame, reason: "relaunched")
    }

    // MARK: - Reordering by dragging

    /// Slide the dragged button through the row as the pointer passes the midpoint
    /// of its neighbours. The button snaps between slots rather than following the
    /// pointer, because the stack view owns the frames.
    private func dragTab(_ button: TabButton, to point: CGPoint) {
        guard let current = buttons.firstIndex(of: button) else { return }
        let others = buttons.filter { $0 !== button }
        var target = others.filter { $0.frame.midX < point.x }.count
        target = max(0, min(target, buttons.count - 1))
        guard target != current else { return }

        button.removeFromSuperview()
        stack.insertArrangedSubview(button, at: target)
        buttons.remove(at: current)
        buttons.insert(button, at: target)
    }

    /// Persist whatever order the buttons ended up in.
    private func commitTabOrder() {
        let order = buttons.compactMap { button in
            workspace.tabs.first { $0.bundleIdentifier == button.bundleIdentifier }
        }
        guard order.count == workspace.tabs.count, order != workspace.tabs else {
            rebuild()   // no change, but the live drag left the row out of step
            return
        }
        let activeID = activeIndex.map { workspace.tabs[$0].bundleIdentifier }
        workspace.tabs = order
        // Indices moved, so the active tab and the hotkeys must be remapped.
        activeIndex = activeID.flatMap { id in order.firstIndex { $0.bundleIdentifier == id } }
        Store.save(workspace)
        rebuild()
        AppDelegate.shared?.registerHotKeys()
        Log.line("reordered: \(order.map(\.name).joined(separator: ", "))")
    }

    /// Move a tab by index. Exists so the reorder can be exercised without a mouse.
    func moveTab(from: Int, to: Int) {
        guard workspace.tabs.indices.contains(from), workspace.tabs.indices.contains(to) else { return }
        let activeID = activeIndex.map { workspace.tabs[$0].bundleIdentifier }
        let tab = workspace.tabs.remove(at: from)
        workspace.tabs.insert(tab, at: to)
        activeIndex = activeID.flatMap { id in workspace.tabs.firstIndex { $0.bundleIdentifier == id } }
        Store.save(workspace)
        rebuild()
        AppDelegate.shared?.registerHotKeys()
        Log.line("reordered: \(workspace.tabs.map(\.name).joined(separator: ", "))")
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
        if id == Bundle.main.bundleIdentifier, !searchField.isHidden {
            searchPanel.makeKeyAndOrderFront(nil)
            searchPanel.makeFirstResponder(searchField)
        }
        refreshRunningApps(promoting: id)
        if workspaceHidden {
            if shouldRestoreHiddenHeader(isHiding: isBulkHiding, appIsHidden: app.isHidden,
                                         appIsHosted: id.map { workspace.hosts(bundleIdentifier: $0) } == true) {
                resumeAfterHide()
            } else {
                panel.orderOut(nil)
                return
            }
        }

        // Keep the highlight on whatever tab is genuinely frontmost, including when
        // you reach it with command-tab rather than by clicking. This is the only
        // thing besides select() allowed to move the active tab.
        if let id, let index = workspace.tabs.firstIndex(where: { $0.bundleIdentifier == id }) {
            activeIndex = index
            rememberActiveTab(index: index)
            highlight(id)
            // Reached without clicking its tab, so nothing has sized it. Snapping
            // here is what stops a tab being active while its window sits at
            // whatever size the app itself last decided on.
            if !workspace.tabs[index].isDetached {
                WindowManager.shared.snap(bundleID: id, in: workspace.contentFrame)
            }
        }

        // Keep the preview visible until the modifier is released.
        guard !commandTabPreview else { return }
        updateStripLevel(for: id)
    }

    private func updateStripLevel(for id: String?) {
        guard !workspaceHidden else {
            panel.orderOut(nil)
            return
        }
        let ours = id == Bundle.main.bundleIdentifier
            || id.map { workspace.hosts(bundleIdentifier: $0) } == true
        // Preview raises the panel independently of isWorkspaceFront, so always
        // restore its level, even when selecting the already-frontmost app.
        isWorkspaceFront = ours

        // Only Host and apps in the workspace get the floating level needed for
        // the strip to sit over a hosted window. Unrelated foreground apps leave
        // the strip at normal level, so their windows can cover it naturally.
        panel.level = ours ? .floating : .normal
        if ours {
            panel.orderFrontRegardless()
        } else {
            panel.orderBack(nil)
        }
        Log.line("\(id ?? "another app") is front; strip level=\(ours ? "floating" : "normal") " +
                 "visible=\(panel.isVisible)")
    }

    /// Order the strip front only if the workspace is what is in front.
    private func showStripIfAppropriate() {
        guard isWorkspaceFront, !workspaceHidden else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Hiding as one unit

    /// Set while we are hiding the other apps ourselves, so their own hide
    /// notifications do not re-enter this and start a cascade.
    private var isBulkHiding = false
    private var workspaceHidden = false
    private var hideGeneration = 0

    private func resumeAfterHide() {
        workspaceHidden = false
        isBulkHiding = false
        hideGeneration += 1
    }

    @objc private func appDidHide(_ note: Notification) {
        guard !isBulkHiding,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              workspace.tabs.contains(where: { $0.bundleIdentifier == id && !$0.isDetached }) else { return }

        isBulkHiding = true
        workspaceHidden = true
        isWorkspaceFront = false
        hideGeneration += 1
        let generation = hideGeneration
        if !searchField.isHidden { closeRunningAppSearch() }
        AppDelegate.shared?.holdWorkspaceForHide()
        Log.line("\(id) hidden; hiding the rest of the workspace")
        for tab in workspace.tabs where tab.bundleIdentifier != id && !tab.isDetached {
            WindowManager.runningApp(tab.bundleIdentifier)?.hide()
        }
        panel.orderOut(nil)

        // Check back before releasing the guard. hide() is a request, and an app
        // that is busy or mid-launch can miss it, which leaves one window of the
        // workspace stranded on screen after everything else has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard self.hideGeneration == generation else { return }
            let stragglers = self.workspace.tabs
                .filter { $0.bundleIdentifier != id && !$0.isDetached }
                .compactMap { WindowManager.runningApp($0.bundleIdentifier) }
                .filter { !$0.isHidden }
            if !stragglers.isEmpty {
                Log.line("  \(stragglers.count) did not hide; asking again")
                stragglers.forEach { $0.hide() }
            }
            self.isBulkHiding = false
        }
    }

    @objc private func appDidUnhide(_ note: Notification) {
        guard !isBulkHiding,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier,
              workspace.tabs.contains(where: { $0.bundleIdentifier == id && !$0.isDetached }) else { return }
        // Only the strip comes back, not every app: unhiding one tab should not
        // drag the other four onto the screen with it.
        //
        // Deliberately does not touch activeIndex. An app unhiding in the
        // background is not you choosing a tab, and letting it reassign the active
        // tab means a later restore brings back the wrong window.
        Log.line("\(id) unhidden; restoring the strip")
        WindowManager.shared.snap(bundleID: id, in: workspace.contentFrame)
        showStripIfAppropriate()
    }

    // MARK: - Following the app window

    /// Set while we reposition the panel ourselves, so the windowDidMove handler
    /// does not read our own move as a user drag and push the window back.
    private var isSyncingStrip = false
    private var geometryPollTimer: Timer?
    private var transientHostedBundleID: String?

    /// The user resized or moved the app window by its own edges. Re-derive the
    /// workspace from the window rather than the other way round, so the strip
    /// keeps sitting exactly on top of it at exactly its width.
    func followWindow(bundleID: String, content: CGRect) {
        // A detached app remains in the running-app header, but its window is
        // outside workspace geometry even when another app is active.
        if workspace.tabs.contains(where: { $0.bundleIdentifier == bundleID && $0.isDetached }) {
            return
        }
        if let active = activeIndex, active < workspace.tabs.count,
           workspace.tabs[active].bundleIdentifier == bundleID {
            guard !workspace.tabs[active].isDetached else { return }
        } else {
            // Apps selected from the running-app header may be placed without
            // becoming persisted tabs. Only that explicitly selected app may
            // drive the strip; a stopped-hosting app must not fall through here.
            guard transientHostedBundleID == bundleID,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        }
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
        rebuild()
        DispatchQueue.main.async { self.isSyncingStrip = false }
        // Resizing one window resizes the workspace, so the rest have to follow too.
        syncEveryTabSoon()
    }

    private func refreshActiveGeometry() {
        guard panel.isVisible else { return }
        if let active = activeIndex, workspace.tabs.indices.contains(active) {
            let tab = workspace.tabs[active]
            guard !tab.isDetached,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == tab.bundleIdentifier
            else { return }
            WindowManager.shared.refreshGeometry(bundleID: tab.bundleIdentifier)
            return
        }

        // Running-app header selections are transient rather than persisted tabs.
        guard let bundleID = transientHostedBundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        WindowManager.shared.refreshGeometry(bundleID: bundleID)
    }
}
