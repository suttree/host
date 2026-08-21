import Cocoa

/// Builds the app icon from a line drawing plus a theme.
///
/// Lives in the app rather than only in the icon tool because the Dock icon is
/// swapped at runtime when the theme changes: macOS has no API to rewrite a
/// signed bundle's .icns, so the themed icon is drawn in process and handed to
/// NSApplication.applicationIconImage.
enum IconRenderer {

    /// The line art, as an alpha mask in black, plus the bounds of its ink.
    typealias Artwork = (mask: NSImage, crop: CGRect)

    // MARK: - Loading

    static func prepare(artworkAt path: String) -> Artwork? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return prepare(image)
    }

    private static var bundled: Artwork??
    static func fromBundle() -> Artwork? {
        if let bundled { return bundled }
        let found = Bundle.main.url(forResource: "artwork", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            .flatMap(prepare)
        bundled = .some(found)
        return found
    }

    /// Redraw into a known pixel layout so the bytes can be read directly.
    private static func normalise(_ image: NSImage) -> NSBitmapImageRep {
        let w = Int(image.size.width), h = Int(image.size.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: w, height: h).fill()
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Dark pixels become opaque, light pixels transparent, and the ink's bounding
    /// box is reported so the drawing's white margin can be cropped away.
    static func prepare(_ image: NSImage) -> Artwork? {
        let source = normalise(image)
        let w = source.pixelsWide, h = source.pixelsHigh
        guard let src = source.bitmapData else { return nil }
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        guard let dst = out.bitmapData else { return nil }

        // Anything lighter than this counts as paper. Well below pure white, so
        // JPEG ringing around the strokes does not survive as a grey wash.
        let paper: CGFloat = 0.72
        var minX = w, minY = h, maxX = -1, maxY = -1

        for y in 0..<h {
            for x in 0..<w {
                let i = y * source.bytesPerRow + x * 4
                let luminance = 0.299 * CGFloat(src[i]) / 255
                              + 0.587 * CGFloat(src[i + 1]) / 255
                              + 0.114 * CGFloat(src[i + 2]) / 255
                let alpha = max(0, min(1, (paper - luminance) / paper))
                let o = y * out.bytesPerRow + x * 4
                dst[o] = 0; dst[o + 1] = 0; dst[o + 2] = 0
                dst[o + 3] = UInt8(alpha * 255)
                if alpha > 0.4 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let mask = NSImage(size: NSSize(width: w, height: h))
        mask.addRepresentation(out)
        // Bitmap rows run top-down, AppKit rects bottom-up.
        let crop = CGRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY),
                          width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        return (mask, crop)
    }

    // MARK: - Rendering

    static func render(theme: Theme, size: CGFloat, artwork: Artwork?) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let pad = size * 0.085
        let body = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
        theme.fillIcon(Theme.squircle(in: body))

        if let artwork {
            // Less padding at small sizes: the strokes scale with the drawing, so a
            // tighter margin is what stops them thinning into mush at 32 and 64 px.
            let margin: CGFloat = size <= 64 ? 0.06 : 0.115
            let available = body.insetBy(dx: body.width * margin, dy: body.width * margin)
            let scale = min(available.width / artwork.crop.width, available.height / artwork.crop.height)
            let drawn = CGSize(width: artwork.crop.width * scale, height: artwork.crop.height * scale)
            let frame = CGRect(x: body.midX - drawn.width / 2, y: body.midY - drawn.height / 2,
                               width: drawn.width, height: drawn.height)
            tinted(artwork, size: drawn, colour: theme.ink).draw(in: frame)
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The mask is black; recolouring happens in its own transparent bitmap so the
    /// sourceAtop fill cannot bleed onto the background behind it.
    private static func tinted(_ artwork: Artwork, size: CGSize, colour: NSColor) -> NSImage {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let full = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        artwork.mask.draw(in: full, from: artwork.crop, operation: .sourceOver, fraction: 1)
        colour.set()
        full.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static let iconSizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]

    /// A multi-representation image, so the Dock and the switcher each pick a size
    /// drawn for them rather than downsampling one big one.
    static func dockImage(theme: Theme, artwork: Artwork?) -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for size in iconSizes {
            image.addRepresentation(render(theme: theme, size: size, artwork: artwork))
        }
        return image
    }
}
