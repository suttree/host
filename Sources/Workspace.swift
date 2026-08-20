import Cocoa

struct AppTab: Codable, Equatable {
    var name: String
    var bundleIdentifier: String

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The workspace is a rectangle on screen plus a strip of chrome along its top.
///
/// There is deliberately no big host window behind the tabs. The external app
/// window is always drawn on top of anything we could put back there, so such a
/// window would be invisible -- and worse, it would sit in the z-order fighting
/// the app we just raised. All we need is the rectangle and the floating strip.
struct Workspace: Codable {
    var tabs: [AppTab]
    var frameString: String
    var stripHeight: CGFloat = 38

    var frame: CGRect {
        get { NSRectFromString(frameString) }
        set { frameString = NSStringFromRect(newValue) }
    }

    /// Cocoa coordinates. The strip sits along the top edge, the app gets the rest.
    var stripFrame: CGRect {
        CGRect(x: frame.minX, y: frame.maxY - stripHeight, width: frame.width, height: stripHeight)
    }

    var contentFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - stripHeight)
    }

    static var defaultFrame: CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1100, visible.width - 80)
        let height = min(780, visible.height - 60)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                      width: width, height: height)
    }

    /// Two apps by default, because one app proves nothing. Every interesting
    /// failure mode -- drift, flicker, focus theft -- only shows up on a switch.
    static var fallback: Workspace {
        var tabs: [AppTab] = []
        for candidate in [("Byword", "com.metaclassy.byword"),
                          ("Safari", "com.apple.Safari"),
                          ("TextEdit", "com.apple.TextEdit")] {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.1) != nil {
                tabs.append(AppTab(name: candidate.0, bundleIdentifier: candidate.1))
            }
            if tabs.count == 2 { break }
        }
        return Workspace(tabs: tabs, frameString: NSStringFromRect(defaultFrame))
    }
}

enum Store {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Host", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workspace.json")
    }

    static func load() -> Workspace {
        guard let data = try? Data(contentsOf: url),
              let workspace = try? JSONDecoder().decode(Workspace.self, from: data) else {
            return .fallback
        }
        return workspace
    }

    static func save(_ workspace: Workspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
