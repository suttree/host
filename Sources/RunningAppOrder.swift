import Foundation

func shouldRestoreHiddenHeader(isHiding: Bool, appIsHidden: Bool, appIsHosted: Bool) -> Bool {
    !isHiding && !appIsHidden && appIsHosted
}

func appSearchMatches(name: String, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !query.isEmpty && name.localizedCaseInsensitiveContains(query)
}

/// Keep a prefix of recent app labels while reserving space for every icon.
func fittingLabelCount(widths: [Double], available: Double, compactWidth: Double = 30) -> Int {
    var remaining = available - Double(widths.count) * compactWidth
    var count = 0
    for width in widths {
        let extra = max(0, width - compactWidth)
        guard remaining >= extra else { break }
        remaining -= extra
        count += 1
    }
    return count
}

/// Keep eligible app identifiers in most-recently-used order.
///
/// `seed` comes from the Window Server's front-to-back window order at launch.
/// After that, activation notifications provide the exact order.
func runningAppOrder(eligible: [String], previous: [String], activated: String? = nil) -> [String] {
    var seen = Set<String>()
    let eligible = eligible.filter { seen.insert($0).inserted }
    let eligibleSet = Set(eligible)
    var order = previous.filter { eligibleSet.contains($0) }

    if let activated, eligibleSet.contains(activated) {
        order.removeAll { $0 == activated }
        order.insert(activated, at: 0)
    }

    let retained = Set(order)
    order.append(contentsOf: eligible.filter { !retained.contains($0) })
    return order
}

/// The leading MRU entries get labels; the rest use compact icon buttons.
func labelledRunningAppIDs(order: [String], limit: Int) -> Set<String> {
    Set(order.prefix(max(0, limit)))
}

/// A stable view of the MRU list while the shortcut modifiers are held.
///
/// The highlighted app is only returned for activation when the modifiers are
/// released, so repeated bracket presses can move in either direction first.
struct RunningAppCycle {
    private var snapshot: [String] = []
    private var index: Int?
    private var pending: String?

    var isActive: Bool { pending != nil }

    mutating func preview(liveOrder: [String], current: String?, offset: Int) -> String? {
        if snapshot.isEmpty {
            snapshot = liveOrder
            index = current.flatMap { snapshot.firstIndex(of: $0) }
        }
        guard let next = relativeTabIndex(activeIndex: index, tabCount: snapshot.count,
                                          offset: offset) else { return nil }
        index = next
        pending = snapshot[next]
        return pending
    }

    mutating func commit() -> String? {
        let selected = pending
        reset()
        return selected
    }

    mutating func reset() {
        snapshot.removeAll()
        index = nil
        pending = nil
    }
}

/// Tracks one Command-Tab gesture without depending on AppKit or Core Graphics.
struct CommandTabGesture {
    private(set) var isActive = false

    mutating func tabPressed(reverse: Bool) -> Int {
        isActive = true
        return reverse ? -1 : 1
    }

    mutating func commandChanged(isDown: Bool) -> Bool {
        guard isActive, !isDown else { return false }
        isActive = false
        return true
    }

    mutating func reset() {
        isActive = false
    }
}
