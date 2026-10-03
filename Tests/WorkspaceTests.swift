import Cocoa

@main
struct WorkspaceTests {
    static func main() {
        var workspace = Workspace(tabs: [], frameString: "{{0, 0}, {1000, 700}}")

        assert(workspace.toggleDetached(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"))
        assert(workspace.tabs == [
            AppTab(name: "Firefox", bundleIdentifier: "org.mozilla.firefox", isDetached: true),
        ])
        assert(!workspace.hosts(bundleIdentifier: "org.mozilla.firefox"))
        assert(!workspace.hosts(bundleIdentifier: "com.apple.Safari"))

        assert(!workspace.toggleDetached(name: "Firefox", bundleIdentifier: "org.mozilla.firefox"))
        assert(!workspace.tabs[0].isDetached)
        assert(workspace.hosts(bundleIdentifier: "org.mozilla.firefox"))

        let browser = AppTab(name: "Browser", bundleIdentifier: "browser")
        let closed = AppTab(name: "Closed", bundleIdentifier: "closed")
        let editor = AppTab(name: "Editor", bundleIdentifier: "editor", isDetached: true)
        let terminal = AppTab(name: "Terminal", bundleIdentifier: "terminal")
        workspace.tabs = [browser, closed, editor, terminal]
        assert(workspace.reorderVisibleTabs(["terminal", "browser", "editor"]))
        assert(workspace.tabs == [terminal, closed, browser, editor])
        let data = try! JSONEncoder().encode(workspace)
        let restored = try! JSONDecoder().decode(Workspace.self, from: data)
        assert(restored.tabs == workspace.tabs)
        assert(!workspace.reorderVisibleTabs(["terminal", "browser", "editor"]))
        assert(!workspace.reorderVisibleTabs(["browser", "browser"]))
        assert(!workspace.reorderVisibleTabs(["unknown"]))
        assert(!workspace.reorderVisibleTabs([]))
        assert(workspace.tabs == restored.tabs)
        assert(workspace.reorderVisibleTabs(["editor", "browser", "closed", "terminal"]))
        assert(workspace.tabs == [editor, browser, closed, terminal])
    }
}
