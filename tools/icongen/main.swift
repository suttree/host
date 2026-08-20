// Draws Host's app icon and writes an .iconset for iconutil.
//
//   build/icongen <output-iconset-dir> [artwork.png]
//
// Compiled with Sources/Sunset.swift so the icon and the tab strip share one
// palette. See `make icon`.
//
// The artwork is expected to be black line art on a white background. It is
// converted to a black image with a real alpha channel and cropped to its ink,
// rather than composited with .multiply. Multiply looks fine in principle but a
// JPEG source has no pure white in it, so the "white" ground comes through as a
// grey haze over the gradient -- and the drawing's generous white margin would
// leave it floating small in the middle of the icon.
import Cocoa

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/Host.iconset"
let artworkPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let artworkImage = artworkPath.flatMap { NSImage(contentsOfFile: $0) }
if artworkPath != nil && artworkImage == nil {
    FileHandle.standardError.write("could not read artwork at \(artworkPath!)\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)


/// Redraw into a known pixel layout so the bytes can be read directly.
func normalise(_ image: NSImage) -> NSBitmapImageRep {
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

/// Turn dark pixels into opaque black and light pixels into transparency, and
/// report the bounding box of the ink in AppKit (bottom-left origin) coordinates.
func inkImage(_ source: NSBitmapImageRep) -> (NSImage, CGRect)? {
    let w = source.pixelsWide, h = source.pixelsHigh
    guard let src = source.bitmapData else { return nil }
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    guard let dst = out.bitmapData else { return nil }

    // Anything lighter than this is treated as paper. Set well below pure white so
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

    let image = NSImage(size: NSSize(width: w, height: h))
    image.addRepresentation(out)
    // Bitmap rows run top-down, AppKit rects bottom-up.
    let crop = CGRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    return (image, crop)
}

let prepared = artworkImage.flatMap { inkImage(normalise($0)) }
if let (_, crop) = prepared {
    print("ink bounds \(Int(crop.width))x\(Int(crop.height)) cropped from \(Int(artworkImage!.size.width))x\(Int(artworkImage!.size.height))")
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // macOS rounded-rect icon proportions.
    let pad = size * 0.085
    let body = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    Sunset.fill(shape, angle: -45, period: body.width * 0.42)

    // Artwork, centred in the icon, scaled to fit while keeping its proportions.
    if let (image, crop) = prepared {
        // Less padding at small sizes. The strokes scale with the drawing, so at
        // 32 and 64 px a smaller margin is what keeps them from thinning into mush.
        let margin: CGFloat = size <= 64 ? 0.06 : 0.125
        let available = body.insetBy(dx: body.width * margin, dy: body.width * margin)
        let scale = min(available.width / crop.width, available.height / crop.height)
        let drawn = CGSize(width: crop.width * scale, height: crop.height * scale)
        let frame = CGRect(x: body.midX - drawn.width / 2, y: body.midY - drawn.height / 2,
                           width: drawn.width, height: drawn.height)
        image.draw(in: frame, from: crop, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                     ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = draw(size: CGFloat(size))
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}
print("wrote iconset to \(outputDir)")
