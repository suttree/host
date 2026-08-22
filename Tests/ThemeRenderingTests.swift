import Cocoa

@main
struct ThemeRenderingTests {
    static func main() {
        let ids = Theme.all.map(\.id)
        assert(Set(ids).count == ids.count)

        let added = Set(["mushroom", "beige", "dune", "starship", "vim", "sunflowers",
                         "silver-black", "polka-dots", "circle-packing", "delaunay-triangles",
                         "harlequin", "sunrise", "lavender", "fern", "heather", "water",
                         "sparkling-water", "supernova", "grainy-bw", "lavender-kitten-grey",
                         "gentle-water", "sea-foam", "hot-pink-stripes", "rose-garden"])
        assert(added.isSubset(of: Set(ids)))
        assert(Theme.all.count == 33)

        for theme in Theme.all {
            assert(theme.swatch(size: NSSize(width: 420, height: 46)).tiffRepresentation != nil)
            let icon = Theme.squircle(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            assert(!icon.isEmpty)
        }

        // The pickers index Theme.sorted, so it must hold every theme exactly once
        // and actually be in order.
        assert(Theme.sorted.count == Theme.all.count)
        assert(Set(Theme.sorted.map(\.id)) == Set(ids))
        let names = Theme.sorted.map(\.name)
        assert(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        assert(Theme.fallback.id == "sunset-stripes")

        let bar = Theme.roundedBarPath(CGRect(x: 0, y: 0, width: 420, height: 46), radius: 10)
        assert(bar.contains(CGPoint(x: 10, y: 10)))
        assert(!bar.contains(CGPoint(x: 0, y: 0)))
        assert(!bar.contains(CGPoint(x: 420, y: 0)))
        assert(!bar.contains(CGPoint(x: 0, y: 46)))
        assert(!bar.contains(CGPoint(x: 420, y: 46)))
    }
}
