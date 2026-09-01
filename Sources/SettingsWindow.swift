import Cocoa

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Host's settings, reachable from the cog on the tab strip.
///
/// This exists because the menu bar is unreachable in practice: it belongs to
/// whichever app is frontmost, and clicking a tab makes that some other app
/// immediately. The View menu still works when Host happens to be frontmost, but
/// it cannot be the only way in.
///
/// Not a true modal. You want to see the strip restyle itself behind the window
/// as you click through the themes, which a modal would prevent.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let columns = 5
    private static let cellWidth: CGFloat = 100
    private static let swatchSize = NSSize(width: 92, height: 34)

    private var themeButtons: [NSButton] = []

    private init() {
        // Resizable, and as tall as the screen sensibly allows. With 33 themes the
        // content is far longer than any fixed height, so a window that cannot be
        // grown leaves whole sections reachable only by scrolling -- or not at all
        // if the scroll view's own height is wrong.
        let available = NSScreen.main?.visibleFrame.height ?? 800
        let height = min(560, max(400, available - 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 360)
        window.level = Self.level(hostIsFront: true)
        window.title = "Host Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        window.contentView = buildContent()
        window.center()
        clampToScreen()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Above the strip while Host is frontmost, ordinary otherwise.
    ///
    /// It has to outrank the strip, because the strip floats so it can cover the
    /// app it hosts and would otherwise cover this window too. But a window that
    /// outranks the strip permanently also sits on top of every other app on the
    /// screen, which is no better than the problem it solves.
    private static func level(hostIsFront: Bool) -> NSWindow.Level {
        hostIsFront ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .normal
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let window, window.isVisible else { return }
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let hostIsFront = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        window.level = Self.level(hostIsFront: hostIsFront)
        Log.line("settings window level=\(hostIsFront ? "above the strip" : "normal") " +
                 "(\(app?.bundleIdentifier ?? "?") is front)")
    }

    /// Keep the whole window on screen. center() places a tall window high enough
    /// that its title bar can end up above the visible frame, out of reach.
    private func clampToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.height = min(frame.height, visible.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: false)
        Log.line("settings window \(NSStringFromRect(frame)) inside \(NSStringFromRect(visible))")
    }

    func show() {
        // The strip is a non-activating panel, so Host is not frontmost when the
        // cog is clicked. Without this the settings window opens behind whatever is.
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        clampToScreen()
        window?.level = Self.level(hostIsFront: true)
        window?.makeKeyAndOrderFront(nil)
        if let scroll = window?.contentView as? NSScrollView,
           let document = scroll.documentView {
            Log.line("settings: content \(Int(document.frame.height))pt, " +
                     "window shows \(Int(scroll.contentView.bounds.height))pt")
        }
    }

    // MARK: - Building

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(heading("Tab bar theme"))
        themeButtons = Theme.sorted.enumerated().map { index, theme in
            swatchButton(image: theme.swatch(size: Self.swatchSize),
                         title: theme.name, tag: index, action: #selector(themeChosen(_:)))
        }
        root.addArrangedSubview(grid(themeButtons, columns: Self.columns, cellWidth: Self.cellWidth))

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = container

        // Let Auto Layout size the document view: its width tracks the clip view
        // and its height falls out of the content. Setting the frame once from
        // fittingSize -- before anything has been laid out -- fixes the scrollable
        // height at a guess, and when that guess is short the sections at the
        // bottom cannot be scrolled to at all.
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return line
    }

    /// An image button with its name underneath, and a layer border used to show
    /// which one is selected.
    private func swatchButton(image: NSImage, title: String, tag: Int, action: Selector) -> NSButton {
        let button = NSButton(image: image, target: self, action: action)
        button.tag = tag
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 3
        button.layer?.borderColor = NSColor.clear.cgColor
        button.toolTip = title
        return button
    }

    /// Every cell is the same fixed width, so the columns line up.
    ///
    /// Letting each cell size to its own contents means the label decides the
    /// width, and one long name -- "Lavender & Kitten Grey" -- shoves its whole
    /// column sideways and the grid stops being a grid. The names wrap to two
    /// lines and truncate rather than widening the cell.
    private func grid(_ buttons: [NSButton], columns: Int, cellWidth: CGFloat) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        for chunk in stride(from: 0, to: buttons.count, by: columns).map({
            Array(buttons[$0..<min($0 + columns, buttons.count)])
        }) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 10
            for button in chunk {
                let cell = NSStackView()
                cell.orientation = .vertical
                cell.alignment = .centerX
                cell.spacing = 3
                cell.translatesAutoresizingMaskIntoConstraints = false

                let label = NSTextField(labelWithString: button.toolTip ?? "")
                label.font = .systemFont(ofSize: 10)
                label.textColor = .secondaryLabelColor
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 2
                label.cell?.wraps = true
                label.preferredMaxLayoutWidth = cellWidth
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)

                cell.addArrangedSubview(button)
                cell.addArrangedSubview(label)
                cell.widthAnchor.constraint(equalToConstant: cellWidth).isActive = true
                row.addArrangedSubview(cell)
            }
            // Short final rows must not stretch to fill the width.
            if chunk.count < columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(filler)
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }

    // MARK: - State

    func refresh() {
        let theme = Theme.current
        for (index, button) in themeButtons.enumerated() {
            button.layer?.borderColor = Theme.sorted[index].id == theme.id
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func themeChosen(_ sender: NSButton) {
        guard Theme.sorted.indices.contains(sender.tag) else { return }
        AppDelegate.shared?.apply(theme: Theme.sorted[sender.tag])
    }

}
