func restoredTabIndex(bundleIDs: [String], lastActiveBundleID: String?) -> Int? {
    guard !bundleIDs.isEmpty else { return nil }
    return lastActiveBundleID.flatMap(bundleIDs.firstIndex) ?? 0
}
