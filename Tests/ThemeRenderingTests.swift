import Cocoa

@main
struct ThemeRenderingTests {
    static func main() {
        let ids = Theme.all.map(\.id)
        assert(Set(ids).count == ids.count)

        let added = Set(["mushroom", "beige", "dune", "starship", "vim", "sunflowers",
                         "silver-black", "polka-dots", "circle-packing", "delaunay-triangles"])
        assert(added.isSubset(of: Set(ids)))

        for theme in Theme.all {
            assert(theme.swatch(size: NSSize(width: 420, height: 46)).tiffRepresentation != nil)
            let icon = Theme.squircle(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            assert(!icon.isEmpty)
        }
    }
}
