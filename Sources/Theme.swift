import Cocoa

/// How a theme paints its surfaces.
enum ThemeStyle {
    /// Solid diagonal bands, in the order given, running from the top-left corner
    /// to the bottom-right. Bold and flat, the way fork does it.
    case stripes([NSColor])
    /// A smooth ramp through the given stops along the same diagonal.
    case gradient([NSColor])
}

struct Theme {
    let id: String
    let name: String
    let style: ThemeStyle
    /// The line art's colour. Pure black is rarely right: warm palettes want a
    /// brown, dark palettes need something light or the drawing disappears.
    let ink: NSColor
    /// Tab titles, and the pill behind the active tab.
    let text: NSColor
    let pill: NSColor
    /// Scattered points of light, for the night skies.
    let stars: Bool

    init(id: String, name: String, style: ThemeStyle, ink: NSColor,
         text: NSColor, pill: NSColor, stars: Bool = false) {
        self.id = id
        self.name = name
        self.style = style
        self.ink = ink
        self.text = text
        self.pill = pill
        self.stars = stars
    }

    // MARK: - Drawing

    /// `stripeWidth` nil fits the whole palette across the shape exactly once,
    /// which is what an icon wants -- tiling makes the pale first band reappear in
    /// the bottom-right corner and the sunset stops reading as a sunset. A width
    /// tiles the palette, which is what a long strip wants.
    func fill(_ path: NSBezierPath, stripeWidth: CGFloat?) {
        switch style {
        case .gradient(let colours):
            let locations = (0..<colours.count).map { CGFloat($0) / CGFloat(max(1, colours.count - 1)) }
            locations.withUnsafeBufferPointer {
                NSGradient(colors: colours, atLocations: $0.baseAddress, colorSpace: .sRGB)?
                    .draw(in: path, angle: -45)
            }
        case .stripes(let colours):
            colours.first?.setFill()
            path.fill()
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            path.addClip()

            // Rotating the context and laying down plain vertical bars is much
            // easier to reason about than working out where each diagonal band
            // meets the edges of a squircle.
            let bounds = path.bounds
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.rotate(byDegrees: -45)
            transform.concat()

            // Extent of the shape measured along the rotated axis: for a W by H
            // rect turned 45 degrees that is (W + H) / sqrt(2).
            let extent = (bounds.width + bounds.height) / 2.0.squareRoot()
            let height = extent * 2

            if let stripeWidth {
                let total = stripeWidth * CGFloat(colours.count)
                var offset = -extent
                while offset < extent {
                    for (i, colour) in colours.enumerated() {
                        colour.setFill()
                        CGRect(x: offset + CGFloat(i) * stripeWidth, y: -height / 2,
                               width: stripeWidth + 0.5, height: height).fill()
                    }
                    offset += total
                }
            } else {
                let width = extent / CGFloat(colours.count)
                for (i, colour) in colours.enumerated() {
                    colour.setFill()
                    CGRect(x: -extent / 2 + CGFloat(i) * width, y: -height / 2,
                           width: width + 0.5, height: height).fill()
                }
            }
            context.restoreGraphicsState()
        }

        if stars { scatterStars(in: path) }
    }

    /// Deterministic, so the icon does not shimmer between redraws.
    private func scatterStars(in path: NSBezierPath) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        path.addClip()
        let bounds = path.bounds
        var seed: UInt64 = 0x5EED
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }
        let count = Int((bounds.width * bounds.height) / 2600)
        for _ in 0..<count {
            let x = bounds.minX + random() * bounds.width
            let y = bounds.minY + random() * bounds.height
            let radius = bounds.width * (0.0016 + random() * 0.0034)
            NSColor(white: 1, alpha: 0.45 + random() * 0.55).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)).fill()
        }
        context.restoreGraphicsState()
    }

    // MARK: - Shapes

    /// A superellipse, not a rounded rectangle. macOS icon corners are continuous
    /// curves, and a circular-cornered rect next to real app icons looks wrong.
    static func squircle(in rect: CGRect, exponent: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let steps = 240
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = rect.midX + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
            let y = rect.midY + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }

    /// Rounded along the top edge only, so the strip sits flush on the window.
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

// MARK: - The set

extension Theme {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let all: [Theme] = [
        Theme(id: "sunset-stripes", name: "Sunset Stripes",
              style: .stripes([rgb(1.00, 0.98, 0.78), rgb(1.00, 0.88, 0.40), rgb(1.00, 0.76, 0.03),
                               rgb(1.00, 0.60, 0.00), rgb(1.00, 0.44, 0.00), rgb(0.90, 0.29, 0.10),
                               rgb(0.75, 0.21, 0.05)]),
              ink: rgb(0.16, 0.09, 0.05), text: .black, pill: NSColor(white: 1, alpha: 0.55)),

        Theme(id: "sunset", name: "Sunset",
              style: .gradient([rgb(0.98, 0.88, 0.48), rgb(0.95, 0.61, 0.22), rgb(0.84, 0.34, 0.18)]),
              ink: rgb(0.14, 0.08, 0.05), text: .black, pill: NSColor(white: 1, alpha: 0.55)),

        Theme(id: "rainbow", name: "Rainbow",
              style: .stripes([rgb(0.93, 0.11, 0.14), rgb(1.00, 0.50, 0.15), rgb(1.00, 0.95, 0.00),
                               rgb(0.13, 0.69, 0.30), rgb(0.00, 0.64, 0.91), rgb(0.25, 0.28, 0.80),
                               rgb(0.64, 0.29, 0.64)]),
              ink: .black, text: .black, pill: NSColor(white: 1, alpha: 0.70)),

        Theme(id: "meadow", name: "Meadow",
              style: .stripes([rgb(0.95, 0.98, 0.87), rgb(0.86, 0.95, 0.69), rgb(0.71, 0.88, 0.48),
                               rgb(0.50, 0.79, 0.31), rgb(0.31, 0.66, 0.23), rgb(0.18, 0.51, 0.21),
                               rgb(0.12, 0.37, 0.18)]),
              ink: rgb(0.07, 0.17, 0.09), text: .black, pill: NSColor(white: 1, alpha: 0.60)),

        Theme(id: "brown", name: "Brown",
              style: .stripes([rgb(0.96, 0.90, 0.82), rgb(0.91, 0.81, 0.66), rgb(0.83, 0.69, 0.48),
                               rgb(0.73, 0.55, 0.33), rgb(0.59, 0.41, 0.23), rgb(0.44, 0.29, 0.16),
                               rgb(0.29, 0.19, 0.10)]),
              ink: rgb(0.16, 0.10, 0.05), text: .black, pill: NSColor(white: 1, alpha: 0.55)),

        Theme(id: "galaxy", name: "Galaxy",
              style: .stripes([rgb(0.29, 0.16, 0.54), rgb(0.24, 0.13, 0.47), rgb(0.20, 0.10, 0.40),
                               rgb(0.16, 0.08, 0.33), rgb(0.13, 0.06, 0.26), rgb(0.09, 0.04, 0.19),
                               rgb(0.06, 0.03, 0.13)]),
              ink: rgb(0.93, 0.88, 1.00), text: .white,
              pill: NSColor(white: 1, alpha: 0.22), stars: true),

        Theme(id: "starry-night", name: "Starry Night",
              style: .stripes([rgb(0.16, 0.28, 0.53), rgb(0.12, 0.23, 0.46), rgb(0.09, 0.19, 0.39),
                               rgb(0.14, 0.26, 0.49), rgb(0.10, 0.21, 0.41), rgb(0.07, 0.16, 0.31),
                               rgb(0.05, 0.12, 0.25)]),
              ink: rgb(0.96, 0.83, 0.42), text: .white,
              pill: NSColor(white: 1, alpha: 0.22), stars: true),

        Theme(id: "hacker", name: "Hacker",
              style: .stripes([rgb(0.05, 0.13, 0.06), rgb(0.03, 0.09, 0.04), rgb(0.06, 0.16, 0.07),
                               rgb(0.02, 0.07, 0.03), rgb(0.05, 0.12, 0.06), rgb(0.03, 0.08, 0.04),
                               rgb(0.01, 0.05, 0.02)]),
              ink: rgb(0.22, 1.00, 0.42), text: rgb(0.60, 1.00, 0.70),
              pill: NSColor(white: 1, alpha: 0.16)),

        Theme(id: "silver", name: "Silver",
              style: .stripes([rgb(0.97, 0.97, 0.98), rgb(0.91, 0.92, 0.94), rgb(0.84, 0.86, 0.89),
                               rgb(0.76, 0.78, 0.82), rgb(0.67, 0.70, 0.75), rgb(0.57, 0.60, 0.66),
                               rgb(0.47, 0.50, 0.56)]),
              ink: rgb(0.10, 0.11, 0.13), text: .black, pill: NSColor(white: 1, alpha: 0.70)),
    ]

    static let fallback = all[0]

    static func named(_ id: String?) -> Theme {
        all.first { $0.id == id } ?? fallback
    }

    // MARK: - Persistence

    private static let key = "HostTheme"

    static var current: Theme {
        get { named(UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }
}
