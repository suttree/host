import Cocoa

/// The sunset treatment, shared by the app icon and the tab strip so the two
/// cannot drift apart. Compiled into the app and into tools/make-icon.swift.
///
/// Colours sampled from the reference icon rather than guessed: pale gold at the
/// top left, through orange, to a red-orange at the bottom right.
enum Sunset {
    static let pale = NSColor(srgbRed: 0.980, green: 0.878, blue: 0.475, alpha: 1) // #FAE079
    static let mid  = NSColor(srgbRed: 0.945, green: 0.612, blue: 0.220, alpha: 1) // #F19C38
    static let deep = NSColor(srgbRed: 0.835, green: 0.337, blue: 0.180, alpha: 1) // #D5562E

    /// Three stops, not two. A straight pale-to-deep ramp passes through a muddy
    /// brown in the middle; the reference stays saturated because orange sits on
    /// the path between them.
    static var gradient: NSGradient {
        let locations: [CGFloat] = [0, 0.45, 1]
        return locations.withUnsafeBufferPointer {
            NSGradient(colors: [pale, mid, deep], atLocations: $0.baseAddress, colorSpace: .sRGB)!
        }
    }

    /// Fill `path` with the gradient and lay diagonal highlight stripes over it.
    /// `period` is the stripe repeat in points, so a small strip and a large icon
    /// can carry the same visual rhythm at different scales.
    static func fill(_ path: NSBezierPath, angle: CGFloat, period: CGFloat) {
        gradient.draw(in: path, angle: angle)
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        path.addClip()

        // Rotating the context and laying down plain vertical bars is far easier to
        // reason about than working out where a diagonal band meets each edge.
        let bounds = path.bounds
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: -45)
        transform.concat()

        let span = (bounds.width + bounds.height) * 1.4
        var offset = -span / 2
        var index = 0
        while offset < span / 2 {
            let wide = index % 2 == 0
            NSColor(white: 1, alpha: wide ? 0.17 : 0.09).setFill()
            CGRect(x: offset, y: -span / 2,
                   width: period * (wide ? 0.34 : 0.15), height: span).fill()
            offset += period
            index += 1
        }
        context.restoreGraphicsState()
    }

    /// Rounded along the top edge only, square along the bottom, so the strip sits
    /// flush on the window beneath it.
    static func topRoundedPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                       radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                       radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }
}

/// The tab strip's background: the same sunset treatment as the app icon.
final class SunsetBarView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Along the bar's length rather than at 45 degrees: the strip is wide and
        // short, so a diagonal ramp would be over within the first few tabs.
        Sunset.fill(Sunset.topRoundedPath(bounds, radius: 9), angle: 0, period: 46)
    }
}
