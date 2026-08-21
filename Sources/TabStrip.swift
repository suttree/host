import Cocoa

/// A borderless, non-activating floating panel.
///
/// Non-activating matters: clicking a tab must not make Host the frontmost
/// application, because the whole point of the click is to make some *other*
/// application frontmost. .floating keeps the strip above the app window we just
/// raised. .managed lets Mission Control sweep it aside with the hosted window,
/// while .canJoinAllSpaces keeps the workspace available on every Space.
final class TabStripPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenNone]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The tab strip's background, in whatever theme is current.
///
/// The palette tiles here rather than being fitted to the shape once, as it is on
/// the icon: the strip is long and short, so one pass would stretch each band into
/// an unreadable smear.
final class ThemeBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.current.fill(Theme.topRoundedPath(bounds, radius: 10), stripeWidth: 34)
    }
}

/// A tab button that distinguishes a click from a drag.
///
/// NSButton's own mouseDown runs a tracking loop and swallows every event until
/// mouseUp, so there is no way to see a drag from the outside. Taking over the
/// loop is the only way to get both behaviours from one press.
final class TabButton: NSButton {
    var bundleIdentifier = ""
    var tabName = ""
    var tabIcon: NSImage?
    var onDragMoved: ((TabButton, CGPoint) -> Void)?
    var onDragEnded: ((TabButton) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        var dragging = false

        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                         until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            // A few points of slop, so a slightly unsteady click is still a click.
            if !dragging && abs(next.locationInWindow.x - start.x) > 4 { dragging = true }
            if dragging, let parent = superview {
                onDragMoved?(self, parent.convert(next.locationInWindow, from: nil))
            }
        }

        if dragging {
            onDragEnded?(self)
        } else if let action, let target {
            sendAction(action, to: target)
        }
    }
}

final class TabStripController: NSObject, NSWindowDelegate {
    private(set) var workspace: Workspace
    private let panel: TabStripPanel
    private let stack = NSStackView()
    private let cog = NSButton()
    private var buttons: [TabButton] = []
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
        cog.toolTip = "Theme and app icon"
        cog.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(cog)
        NSLayoutConstraint.activate([
            cog.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            cog.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cog.widthAnchor.constraint(equalToConstant: 30),
            cog.heightAnchor.constraint(equalToConstant: 26),
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
            let button = TabButton(title: "", target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.bundleIdentifier = tab.bundleIdentifier
            button.tabName = tab.name
            button.tabIcon = tab.icon
            button.onDragMoved = { [weak self] b, point in self?.dragTab(b, to: point) }
            button.onDragEnded = { [weak self] _ in self?.commitTabOrder() }
            style(button, title: tab.name)
            button.toolTip = "\(tab.bundleIdentifier)   (option-\(index + 1))"

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

        let add = symbolButton("plus", tooltip: "Add an application",
                               action: #selector(addClicked))
        stack.addArrangedSubview(add)

        highlight(activeIndex)

        cog.layer?.backgroundColor = Theme.current.chip.withAlphaComponent(0.55).cgColor
        cog.contentTintColor = Theme.current.text
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
        button.alphaValue = active ? 1 : 0.52
        button.attributedTitle = Self.tabTitle(button.tabName, icon: button.tabIcon, active: active)
    }

    private func highlight(_ index: Int?) {
        for (i, button) in buttons.enumerated() {
            applyChip(button, active: i == index)
        }
    }

    /// Repaint the strip after the theme changes. The buttons are rebuilt because
    /// their title colour is baked into an attributed string.
    func applyTheme() {
        panel.contentView?.needsDisplay = true
        rebuild()
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

    func selectRelative(offset: Int) {
        guard let index = relativeTabIndex(activeIndex: activeIndex,
                                           tabCount: workspace.tabs.count,
                                           offset: offset) else { return }
        select(index: index)
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

    /// Bring the workspace back after it has been hidden: the strip and the tab
    /// that was active when it went away. Raising the strip alone leaves a bar
    /// floating over nothing.
    ///
    /// Only the active tab is unhidden, not all of them, for the same reason
    /// appDidUnhide does not: coming back to one tab should not haul the other
    /// four onto the screen with it.
    func restoreWorkspace() {
        raiseStrip()
        guard !workspace.tabs.isEmpty else { return }
        let index = activeIndex ?? 0
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
        let ours = id == Bundle.main.bundleIdentifier
            || workspace.tabs.contains { $0.bundleIdentifier == id }

        // Keep the highlight on whatever tab is genuinely frontmost, including when
        // you reach it with command-tab rather than by clicking. This is the only
        // thing besides select() allowed to move the active tab.
        if let id, let index = workspace.tabs.firstIndex(where: { $0.bundleIdentifier == id }) {
            activeIndex = index
            highlight(index)
            // Reached without clicking its tab, so nothing has sized it. Snapping
            // here is what stops a tab being active while its window sits at
            // whatever size the app itself last decided on.
            WindowManager.shared.snap(bundleID: id, in: workspace.contentFrame)
        }

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

        // Check back before releasing the guard. hide() is a request, and an app
        // that is busy or mid-launch can miss it, which leaves one window of the
        // workspace stranded on screen after everything else has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let stragglers = self.workspace.tabs
                .filter { $0.bundleIdentifier != id }
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
              workspace.tabs.contains(where: { $0.bundleIdentifier == id }) else { return }
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
