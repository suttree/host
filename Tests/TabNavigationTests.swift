@main
struct TabNavigationTests {
    static func main() {
        assert(relativeTabIndex(activeIndex: 1, tabCount: 4, offset: 1) == 2)
        assert(relativeTabIndex(activeIndex: 1, tabCount: 4, offset: -1) == 0)
        assert(relativeTabIndex(activeIndex: 3, tabCount: 4, offset: 1) == 0)
        assert(relativeTabIndex(activeIndex: 0, tabCount: 4, offset: -1) == 3)
        assert(relativeTabIndex(activeIndex: nil, tabCount: 4, offset: 1) == 0)
        assert(relativeTabIndex(activeIndex: nil, tabCount: 4, offset: -1) == 3)
        assert(relativeTabIndex(activeIndex: nil, tabCount: 0, offset: 1) == nil)
    }
}
