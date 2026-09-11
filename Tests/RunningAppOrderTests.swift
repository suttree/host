import Foundation

@main
struct RunningAppOrderTests {
    static func main() {
        // Finder or another unhosted app becoming active must leave the bar hidden.
        assert(!shouldRestoreHiddenHeader(isHiding: false, appIsHidden: false, appIsHosted: false))
        assert(!shouldRestoreHiddenHeader(isHiding: true, appIsHidden: false, appIsHosted: true))
        assert(!shouldRestoreHiddenHeader(isHiding: false, appIsHidden: true, appIsHosted: true))
        assert(shouldRestoreHiddenHeader(isHiding: false, appIsHidden: false, appIsHosted: true))
        assert(appSearchMatches(name: "Firefox", query: "  FIRE  "))
        assert(appSearchMatches(name: "Mail", query: "ai"))
        assert(!appSearchMatches(name: "Firefox", query: "mail"))
        assert(!appSearchMatches(name: "Firefox", query: "  "))
        assert(fittingLabelCount(widths: [100, 90, 80], available: 270) == 3)
        assert(fittingLabelCount(widths: [100, 90, 80], available: 160) == 1)
        assert(fittingLabelCount(widths: [100, 90, 80], available: 90) == 0)
        assert(fittingLabelCount(widths: [100, 90, 80], available: 60) == 0)
        assert(fittingLabelCount(widths: [], available: 0) == 0)
        assert(runningAppOrder(eligible: ["mail", "notes", "mail"], previous: []) == ["mail", "notes"])
        assert(runningAppOrder(eligible: ["mail", "notes", "music"],
                               previous: ["notes", "mail"],
                               activated: "music") == ["music", "notes", "mail"])
        assert(runningAppOrder(eligible: ["mail", "music"],
                               previous: ["music", "notes", "mail"]) == ["music", "mail"])
        assert(runningAppOrder(eligible: ["mail", "notes"],
                               previous: ["mail", "notes"],
                               activated: "finder") == ["mail", "notes"])
        assert(labelledRunningAppIDs(order: ["mail", "notes", "music"], limit: 2)
            == Set(["mail", "notes"]))
        assert(labelledRunningAppIDs(order: ["music", "mail", "notes"], limit: 2)
            == Set(["music", "mail"]))
        assert(labelledRunningAppIDs(order: ["mail"], limit: 0).isEmpty)

        var cycle = RunningAppCycle()
        assert(cycle.preview(liveOrder: ["mail", "notes", "music"], current: "mail",
                             offset: 1) == "notes")
        // Previewing does not commit. Further presses continue through the stable
        // snapshot even if the live MRU order changes underneath it.
        assert(cycle.preview(liveOrder: ["notes", "mail", "music"], current: "mail",
                             offset: 1) == "music")
        assert(cycle.preview(liveOrder: ["music", "notes", "mail"], current: "mail",
                             offset: -1) == "notes")
        assert(cycle.commit() == "notes")
        assert(cycle.commit() == nil)
        assert(cycle.preview(liveOrder: ["music", "notes", "mail"], current: "music",
                             offset: -1) == "mail")

        var commandTab = CommandTabGesture()
        assert(commandTab.tabPressed(reverse: false) == 1)
        assert(commandTab.tabPressed(reverse: true) == -1)
        assert(!commandTab.commandChanged(isDown: true))
        assert(commandTab.commandChanged(isDown: false))
        assert(!commandTab.commandChanged(isDown: false))
    }
}
