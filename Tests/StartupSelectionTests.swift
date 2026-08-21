@main
struct StartupSelectionTests {
    static func main() {
        let tabs = ["chat", "terminal", "music"]
        assert(restoredTabIndex(bundleIDs: tabs, lastActiveBundleID: "terminal") == 1)
        assert(restoredTabIndex(bundleIDs: tabs, lastActiveBundleID: "missing") == 0)
        assert(restoredTabIndex(bundleIDs: tabs, lastActiveBundleID: nil) == 0)
        assert(restoredTabIndex(bundleIDs: [], lastActiveBundleID: "chat") == nil)
    }
}
