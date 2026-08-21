func relativeTabIndex(activeIndex: Int?, tabCount: Int, offset: Int) -> Int? {
    guard tabCount > 0 else { return nil }
    let startingIndex = activeIndex ?? (offset < 0 ? 0 : -1)
    return (startingIndex + offset + tabCount) % tabCount
}
