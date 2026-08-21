import Cocoa

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

    private var themeButtons: [NSButton] = []
    private var iconButtons: [NSButton] = []
    private var followCheckbox: NSButton!

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Host Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // The strip is a non-activating panel, so Host is not frontmost when the
        // cog is clicked. Without this the settings window opens behind whatever is.
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        window?.makeKeyAndOrderFront(nil)
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
        themeButtons = Theme.all.enumerated().map { index, theme in
            swatchButton(image: theme.swatch(size: NSSize(width: 140, height: 34)),
                         title: theme.name, tag: index, action: #selector(themeChosen(_:)))
        }
        root.addArrangedSubview(grid(themeButtons, columns: 3))

        root.addArrangedSubview(separator())

        root.addArrangedSubview(heading("App icon"))
        followCheckbox = NSButton(checkboxWithTitle: "Match the tab bar theme",
                                  target: self, action: #selector(followToggled(_:)))
        root.addArrangedSubview(followCheckbox)

        let artwork = IconRenderer.fromBundle()
        iconButtons = Theme.all.enumerated().map { index, theme in
            let rep = IconRenderer.render(theme: theme, size: 128, artwork: artwork)
            let image = NSImage(size: NSSize(width: 64, height: 64))
            image.addRepresentation(rep)
            return swatchButton(image: image, title: theme.name, tag: index,
                                action: #selector(iconChosen(_:)))
        }
        root.addArrangedSubview(grid(iconButtons, columns: 5))

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
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

    private func grid(_ buttons: [NSButton], columns: Int) -> NSView {
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
                let label = NSTextField(labelWithString: button.toolTip ?? "")
                label.font = .systemFont(ofSize: 10)
                label.textColor = .secondaryLabelColor
                cell.addArrangedSubview(button)
                cell.addArrangedSubview(label)
                row.addArrangedSubview(cell)
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }

    // MARK: - State

    func refresh() {
        guard followCheckbox != nil else { return }
        let theme = Theme.current
        let icon = Theme.iconTheme
        for (index, button) in themeButtons.enumerated() {
            button.layer?.borderColor = Theme.all[index].id == theme.id
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        for (index, button) in iconButtons.enumerated() {
            button.layer?.borderColor = Theme.all[index].id == icon.id
                ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            // Deliberately never disabled. Dimming them out while "match" is
            // ticked means you have to untick first to do the obvious thing;
            // clicking an icon simply unticks it for you.
            button.alphaValue = 1
        }
        followCheckbox.state = Theme.iconFollowsTheme ? .on : .off
    }

    @objc private func themeChosen(_ sender: NSButton) {
        guard Theme.all.indices.contains(sender.tag) else { return }
        AppDelegate.shared?.apply(theme: Theme.all[sender.tag])
    }

    @objc private func iconChosen(_ sender: NSButton) {
        guard Theme.all.indices.contains(sender.tag) else { return }
        AppDelegate.shared?.apply(iconTheme: Theme.all[sender.tag])
    }

    @objc private func followToggled(_ sender: NSButton) {
        Theme.iconFollowsTheme = sender.state == .on
        AppDelegate.shared?.refreshAppearance()
    }
}
