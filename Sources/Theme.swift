import Cocoa

/// How a theme paints its surfaces.
enum ThemeStyle {
    /// Solid diagonal bands, in the order given, running from the top-left corner
    /// to the bottom-right. Bold and flat, the way fork does it.
    case stripes([NSColor])
    /// A smooth ramp through the given stops along the same diagonal.
    case gradient([NSColor])
    case polkaDots(background: NSColor, dots: [NSColor])
    case packedCircles(background: NSColor, circles: [NSColor], seed: UInt64)
    case triangles([NSColor], seed: UInt64)
    case sunflowers(background: NSColor, petals: [NSColor], centre: NSColor)
    case diamonds(background: NSColor, diamonds: [NSColor])
    case waves(background: NSColor, waves: [NSColor])
    case bubbles(background: NSColor, bubbles: [NSColor], seed: UInt64)
    case radial([NSColor])
    case grain(background: NSColor, shades: [NSColor], seed: UInt64)
}

struct Theme {
    let id: String
    let name: String
    let style: ThemeStyle
    /// The line art's colour. Pure black is rarely right: warm palettes want a
    /// brown, dark palettes need something light or the drawing disappears.
    let ink: NSColor
    /// Tab titles, and the card each tab's icon and name sit on.
    ///
    /// The card is what makes the stripes free to be as bold as they like: text
    /// never touches the background, so contrast is a property of the card rather
    /// than of whichever band happens to pass behind a given tab.
    let text: NSColor
    let chip: NSColor
    /// A stable seed for scattered dots and stars. Nil leaves the surface clear.
    let starSeed: UInt64?

    init(id: String, name: String, style: ThemeStyle, ink: NSColor,
         text: NSColor, chip: NSColor, starSeed: UInt64? = nil) {
        self.id = id
        self.name = name
        self.style = style
        self.ink = ink
        self.text = text
        self.chip = chip
        self.starSeed = starSeed
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
        case .polkaDots(let background, let dots):
            drawPolkaDots(in: path, background: background, dots: dots, tiled: stripeWidth != nil)
        case .packedCircles(let background, let circles, let seed):
            drawPackedCircles(in: path, background: background, colours: circles,
                              seed: seed, tiled: stripeWidth != nil)
        case .triangles(let colours, let seed):
            drawTriangles(in: path, colours: colours, seed: seed, tiled: stripeWidth != nil)
        case .sunflowers(let background, let petals, let centre):
            drawSunflowers(in: path, background: background, petals: petals,
                           centre: centre, tiled: stripeWidth != nil)
        case .diamonds(let background, let diamonds):
            drawDiamonds(in: path, background: background, colours: diamonds,
                         tiled: stripeWidth != nil)
        case .waves(let background, let waves):
            drawWaves(in: path, background: background, colours: waves,
                      tiled: stripeWidth != nil)
        case .bubbles(let background, let bubbles, let seed):
            drawBubbles(in: path, background: background, colours: bubbles,
                        seed: seed, tiled: stripeWidth != nil)
        case .radial(let colours):
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            path.addClip()
            let locations = (0..<colours.count).map { CGFloat($0) / CGFloat(max(1, colours.count - 1)) }
            locations.withUnsafeBufferPointer {
                let gradient = NSGradient(colors: colours, atLocations: $0.baseAddress, colorSpace: .sRGB)
                let bounds = path.bounds
                gradient?.draw(fromCenter: CGPoint(x: bounds.midX * 0.82, y: bounds.midY * 1.18),
                               radius: 0, toCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                               radius: hypot(bounds.width, bounds.height) * 0.62, options: [])
            }
            context.restoreGraphicsState()
        case .grain(let background, let shades, let seed):
            drawGrain(in: path, background: background, shades: shades,
                      seed: seed, tiled: stripeWidth != nil)
        }

        if let starSeed { scatterStars(in: path, seed: starSeed) }
    }

    private func clipped(_ path: NSBezierPath, background: NSColor, draw: (CGRect) -> Void) {
        background.setFill()
        path.fill()
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        path.addClip()
        draw(path.bounds)
        context.restoreGraphicsState()
    }

    private func drawPolkaDots(in path: NSBezierPath, background: NSColor,
                               dots: [NSColor], tiled: Bool) {
        clipped(path, background: background) { bounds in
            let spacing = tiled ? CGFloat(24) : bounds.width / 7
            let radius = spacing * 0.22
            var row = 0
            var y = bounds.minY - spacing
            while y < bounds.maxY + spacing {
                var column = 0
                var x = bounds.minX - spacing + (row.isMultiple(of: 2) ? 0 : spacing / 2)
                while x < bounds.maxX + spacing {
                    dots[(row + column) % dots.count].setFill()
                    NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)).fill()
                    column += 1
                    x += spacing
                }
                row += 1
                y += spacing
            }
        }
    }

    private func drawPackedCircles(in path: NSBezierPath, background: NSColor,
                                   colours: [NSColor], seed initialSeed: UInt64, tiled: Bool) {
        clipped(path, background: background) { bounds in
            var seed = initialSeed
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 100_000) / 100_000
            }
            let scale = tiled ? max(bounds.height, 44) : bounds.width
            let target = max(20, Int(bounds.width * bounds.height / (scale * scale) * 90))
            var circles: [(CGPoint, CGFloat)] = []
            for _ in 0..<(target * 12) where circles.count < target {
                let radius = scale * (0.025 + random() * 0.07)
                let centre = CGPoint(x: bounds.minX + random() * bounds.width,
                                     y: bounds.minY + random() * bounds.height)
                guard circles.allSatisfy({ hypot($0.0.x - centre.x, $0.0.y - centre.y) > $0.1 + radius + 1 }) else {
                    continue
                }
                colours[circles.count % colours.count].setFill()
                NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2)).fill()
                circles.append((centre, radius))
            }
        }
    }

    private func drawTriangles(in path: NSBezierPath, colours: [NSColor],
                               seed initialSeed: UInt64, tiled: Bool) {
        clipped(path, background: colours[0]) { bounds in
            var seed = initialSeed
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 100_000) / 100_000
            }
            let cell = tiled ? CGFloat(38) : bounds.width / 5
            var row = 0
            var y = bounds.minY - cell
            while y < bounds.maxY + cell {
                var column = 0
                var x = bounds.minX - cell
                while x < bounds.maxX + cell {
                    let skew = (random() - 0.5) * cell * 0.45
                    let points = [CGPoint(x: x, y: y), CGPoint(x: x + cell, y: y),
                                  CGPoint(x: x + cell + skew, y: y + cell),
                                  CGPoint(x: x + skew, y: y + cell)]
                    for indices in [[0, 1, 2], [0, 2, 3]] {
                        colours[(row * 2 + column + indices[1]) % colours.count].setFill()
                        let triangle = NSBezierPath()
                        triangle.move(to: points[indices[0]])
                        triangle.line(to: points[indices[1]])
                        triangle.line(to: points[indices[2]])
                        triangle.close()
                        triangle.fill()
                    }
                    column += 1
                    x += cell
                }
                row += 1
                y += cell
            }
        }
    }

    private func drawSunflowers(in path: NSBezierPath, background: NSColor,
                                petals: [NSColor], centre: NSColor, tiled: Bool) {
        clipped(path, background: background) { bounds in
            let spacing = tiled ? CGFloat(42) : bounds.width / 4
            var row = 0
            var y = bounds.minY - spacing / 2
            while y < bounds.maxY + spacing {
                var column = 0
                var x = bounds.minX + (row.isMultiple(of: 2) ? 0 : spacing / 2)
                while x < bounds.maxX + spacing {
                    let flowerCentre = CGPoint(x: x, y: y)
                    for petal in 0..<10 {
                        let angle = CGFloat(petal) * .pi / 5
                        let petalCentre = CGPoint(x: x + cos(angle) * spacing * 0.18,
                                                 y: y + sin(angle) * spacing * 0.18)
                        petals[(row + column + petal) % petals.count].setFill()
                        NSBezierPath(ovalIn: CGRect(x: petalCentre.x - spacing * 0.07,
                                                   y: petalCentre.y - spacing * 0.12,
                                                   width: spacing * 0.14, height: spacing * 0.24)).fill()
                    }
                    centre.setFill()
                    NSBezierPath(ovalIn: CGRect(x: flowerCentre.x - spacing * 0.10,
                                               y: flowerCentre.y - spacing * 0.10,
                                               width: spacing * 0.20, height: spacing * 0.20)).fill()
                    column += 1
                    x += spacing
                }
                row += 1
                y += spacing
            }
        }
    }

    private func drawDiamonds(in path: NSBezierPath, background: NSColor,
                              colours: [NSColor], tiled: Bool) {
        clipped(path, background: background) { bounds in
            let width = tiled ? CGFloat(34) : bounds.width / 5
            let height = width * 0.72
            var row = 0
            var y = bounds.minY - height
            while y < bounds.maxY + height {
                var column = 0
                var x = bounds.minX - width + (row.isMultiple(of: 2) ? 0 : width / 2)
                while x < bounds.maxX + width {
                    colours[(row + column) % colours.count].setFill()
                    let diamond = NSBezierPath()
                    diamond.move(to: CGPoint(x: x, y: y + height / 2))
                    diamond.line(to: CGPoint(x: x + width / 2, y: y + height))
                    diamond.line(to: CGPoint(x: x + width, y: y + height / 2))
                    diamond.line(to: CGPoint(x: x + width / 2, y: y))
                    diamond.close()
                    diamond.fill()
                    column += 1
                    x += width
                }
                row += 1
                y += height / 2
            }
        }
    }

    private func drawWaves(in path: NSBezierPath, background: NSColor,
                           colours: [NSColor], tiled: Bool) {
        clipped(path, background: background) { bounds in
            let spacing = tiled ? CGFloat(13) : bounds.height / 11
            let amplitude = spacing * 0.42
            for row in -2...Int(bounds.height / spacing) + 2 {
                let wave = NSBezierPath()
                wave.lineWidth = max(2, spacing * 0.52)
                var x = bounds.minX - 10
                while x <= bounds.maxX + 10 {
                    let y = bounds.minY + CGFloat(row) * spacing
                        + sin((x - bounds.minX) / spacing * .pi) * amplitude
                    if x == bounds.minX - 10 { wave.move(to: CGPoint(x: x, y: y)) }
                    else { wave.line(to: CGPoint(x: x, y: y)) }
                    x += 4
                }
                colours[(row + colours.count * 2) % colours.count].setStroke()
                wave.stroke()
            }
        }
    }

    private func drawBubbles(in path: NSBezierPath, background: NSColor,
                             colours: [NSColor], seed initialSeed: UInt64, tiled: Bool) {
        clipped(path, background: background) { bounds in
            var seed = initialSeed
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 100_000) / 100_000
            }
            let scale = tiled ? max(bounds.height, 44) : bounds.width
            let count = max(24, Int(bounds.width * bounds.height / (scale * scale) * 120))
            for bubble in 0..<count {
                let radius = scale * (0.012 + random() * 0.055)
                let x = bounds.minX + random() * bounds.width
                let y = bounds.minY + random() * bounds.height
                let circle = NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                                         width: radius * 2, height: radius * 2))
                circle.lineWidth = max(1, radius * 0.18)
                colours[bubble % colours.count].setStroke()
                circle.stroke()
            }
        }
    }

    private func drawGrain(in path: NSBezierPath, background: NSColor,
                           shades: [NSColor], seed initialSeed: UInt64, tiled: Bool) {
        clipped(path, background: background) { bounds in
            var seed = initialSeed
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 100_000) / 100_000
            }
            let divisor: CGFloat = tiled ? 65 : 220
            let count = Int(bounds.width * bounds.height / divisor)
            let scale = max(1, min(bounds.width, bounds.height) * 0.004)
            for speck in 0..<count {
                let size = scale * (0.4 + random() * 1.8)
                let colour = shades[speck % shades.count].withAlphaComponent(0.08 + random() * 0.30)
                colour.setFill()
                CGRect(x: bounds.minX + random() * bounds.width,
                       y: bounds.minY + random() * bounds.height,
                       width: size, height: size).fill()
            }
        }
    }

    /// Deterministic, so the icon does not shimmer between redraws.
    private func scatterStars(in path: NSBezierPath, seed initialSeed: UInt64) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        path.addClip()
        let bounds = path.bounds
        var seed = initialSeed
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }
        let count = Int((bounds.width * bounds.height) / 2000)
        for index in 0..<count {
            let x = bounds.minX + random() * bounds.width
            let y = bounds.minY + random() * bounds.height
            let scale = min(bounds.width, max(bounds.height, 300))
            let radius = scale * (0.0012 + random() * 0.0015)
            NSColor(white: 1, alpha: 0.45 + random() * 0.55).setFill()
            if index.isMultiple(of: 4) {
                starPath(at: CGPoint(x: x, y: y), outerRadius: radius * 1.6).fill()
            } else {
                NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2)).fill()
            }
        }
        context.restoreGraphicsState()
    }

    private func starPath(at centre: CGPoint, outerRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let innerRadius = outerRadius * 0.42
        for point in 0..<10 {
            let radius = point.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = -.pi / 2 + CGFloat(point) * .pi / 5
            let position = CGPoint(x: centre.x + cos(angle) * radius,
                                   y: centre.y + sin(angle) * radius)
            if point == 0 { path.move(to: position) } else { path.line(to: position) }
        }
        path.close()
        return path
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
              ink: rgb(0.16, 0.09, 0.05), text: .black, chip: rgb(0.98, 0.97, 0.95)),

        Theme(id: "sunset", name: "Sunset",
              style: .gradient([rgb(0.98, 0.88, 0.48), rgb(0.95, 0.61, 0.22), rgb(0.84, 0.34, 0.18)]),
              ink: rgb(0.14, 0.08, 0.05), text: .black, chip: rgb(0.98, 0.97, 0.95)),

        Theme(id: "rainbow", name: "Rainbow",
              style: .stripes([rgb(0.93, 0.11, 0.14), rgb(1.00, 0.50, 0.15), rgb(1.00, 0.95, 0.00),
                               rgb(0.13, 0.69, 0.30), rgb(0.00, 0.64, 0.91), rgb(0.25, 0.28, 0.80),
                               rgb(0.64, 0.29, 0.64)]),
              ink: .black, text: .black, chip: rgb(0.98, 0.97, 0.95)),

        Theme(id: "meadow", name: "Meadow",
              style: .stripes([rgb(0.95, 0.98, 0.87), rgb(0.86, 0.95, 0.69), rgb(0.71, 0.88, 0.48),
                               rgb(0.50, 0.79, 0.31), rgb(0.31, 0.66, 0.23), rgb(0.18, 0.51, 0.21),
                               rgb(0.12, 0.37, 0.18)]),
              ink: rgb(0.07, 0.17, 0.09), text: .black, chip: rgb(0.98, 0.97, 0.95)),

        Theme(id: "brown", name: "Brown",
              style: .stripes([rgb(0.96, 0.90, 0.82), rgb(0.91, 0.81, 0.66), rgb(0.83, 0.69, 0.48),
                               rgb(0.73, 0.55, 0.33), rgb(0.59, 0.41, 0.23), rgb(0.44, 0.29, 0.16),
                               rgb(0.29, 0.19, 0.10)]),
              ink: rgb(0.16, 0.10, 0.05), text: .black, chip: rgb(0.98, 0.97, 0.95)),

        Theme(id: "galaxy", name: "Galaxy",
              style: .stripes([rgb(0.29, 0.16, 0.54), rgb(0.24, 0.13, 0.47), rgb(0.20, 0.10, 0.40),
                               rgb(0.16, 0.08, 0.33), rgb(0.13, 0.06, 0.26), rgb(0.09, 0.04, 0.19),
                               rgb(0.06, 0.03, 0.13)]),
              ink: rgb(0.93, 0.88, 1.00), text: rgb(0.95, 0.92, 1.00),
              chip: rgb(0.13, 0.07, 0.26), starSeed: 0x5EED),

        Theme(id: "starry-night", name: "Starry Night",
              style: .stripes([rgb(0.16, 0.28, 0.53), rgb(0.12, 0.23, 0.46), rgb(0.09, 0.19, 0.39),
                               rgb(0.14, 0.26, 0.49), rgb(0.10, 0.21, 0.41), rgb(0.07, 0.16, 0.31),
                               rgb(0.05, 0.12, 0.25)]),
              ink: rgb(0.96, 0.83, 0.42), text: rgb(0.98, 0.90, 0.62),
              chip: rgb(0.06, 0.13, 0.27), starSeed: 0x57A22),

        Theme(id: "hacker", name: "Hacker",
              style: .stripes([rgb(0.05, 0.13, 0.06), rgb(0.03, 0.09, 0.04), rgb(0.06, 0.16, 0.07),
                               rgb(0.02, 0.07, 0.03), rgb(0.05, 0.12, 0.06), rgb(0.03, 0.08, 0.04),
                               rgb(0.01, 0.05, 0.02)]),
              ink: rgb(0.22, 1.00, 0.42), text: rgb(0.45, 1.00, 0.60),
              chip: rgb(0.02, 0.07, 0.03)),

        Theme(id: "mushroom", name: "Mushroom",
              style: .polkaDots(background: rgb(0.91, 0.80, 0.64),
                                dots: [rgb(0.52, 0.17, 0.12), rgb(0.72, 0.31, 0.20), rgb(0.96, 0.88, 0.69)]),
              ink: rgb(0.25, 0.10, 0.07), text: rgb(0.20, 0.09, 0.06), chip: rgb(0.96, 0.90, 0.78)),

        Theme(id: "beige", name: "Beige",
              style: .gradient([rgb(0.96, 0.93, 0.85), rgb(0.87, 0.81, 0.69), rgb(0.73, 0.64, 0.51)]),
              ink: rgb(0.25, 0.21, 0.16), text: rgb(0.19, 0.16, 0.12), chip: rgb(0.97, 0.94, 0.87)),

        Theme(id: "dune", name: "Dune",
              style: .gradient([rgb(0.95, 0.72, 0.37), rgb(0.77, 0.43, 0.22), rgb(0.32, 0.20, 0.22),
                                rgb(0.09, 0.25, 0.31)]),
              ink: rgb(0.10, 0.08, 0.07), text: rgb(0.18, 0.10, 0.06), chip: rgb(0.96, 0.82, 0.59)),

        Theme(id: "starship", name: "Starship",
              style: .triangles([rgb(0.02, 0.04, 0.10), rgb(0.05, 0.10, 0.20), rgb(0.08, 0.22, 0.30),
                                 rgb(0.22, 0.08, 0.30), rgb(0.38, 0.08, 0.35)], seed: 0x57A2511),
              ink: rgb(0.62, 1.00, 0.94), text: rgb(0.78, 1.00, 0.96),
              chip: rgb(0.03, 0.08, 0.14), starSeed: 0xC05A05),

        Theme(id: "vim", name: "Vim",
              style: .stripes([rgb(0.00, 0.24, 0.12), rgb(0.00, 0.38, 0.20), rgb(0.08, 0.54, 0.29),
                               rgb(0.14, 0.25, 0.36), rgb(0.08, 0.15, 0.25), rgb(0.02, 0.08, 0.12)]),
              ink: rgb(0.63, 1.00, 0.68), text: rgb(0.76, 1.00, 0.79), chip: rgb(0.02, 0.16, 0.10)),

        Theme(id: "sunflowers", name: "Sunflowers",
              style: .sunflowers(background: rgb(0.18, 0.39, 0.22),
                                  petals: [rgb(1.00, 0.80, 0.06), rgb(0.95, 0.56, 0.02)],
                                  centre: rgb(0.27, 0.12, 0.04)),
              ink: rgb(0.19, 0.09, 0.03), text: rgb(0.20, 0.10, 0.03), chip: rgb(1.00, 0.88, 0.35)),

        Theme(id: "silver-black", name: "Silver / Black",
              style: .stripes([rgb(0.05, 0.05, 0.06), rgb(0.22, 0.23, 0.25), rgb(0.48, 0.50, 0.54),
                               rgb(0.82, 0.83, 0.85), rgb(0.38, 0.39, 0.42), rgb(0.10, 0.10, 0.11)]),
              ink: .white, text: .white, chip: rgb(0.10, 0.10, 0.11)),

        Theme(id: "grainy-bw", name: "Grainy B&W",
              style: .grain(background: rgb(0.05, 0.05, 0.05),
                            shades: [rgb(1.00, 1.00, 1.00), rgb(0.68, 0.68, 0.68), rgb(0.32, 0.32, 0.32)],
                            seed: 0xB1ACAAAD),
              ink: .white, text: .white, chip: rgb(0.11, 0.11, 0.11)),

        Theme(id: "polka-dots", name: "Polka Dots",
              style: .polkaDots(background: rgb(0.98, 0.88, 0.86),
                                dots: [rgb(0.91, 0.19, 0.29), rgb(0.16, 0.57, 0.73), rgb(0.98, 0.65, 0.12)]),
              ink: rgb(0.18, 0.12, 0.15), text: rgb(0.17, 0.10, 0.13), chip: rgb(1.00, 0.97, 0.94)),

        Theme(id: "circle-packing", name: "Circle Packing",
              style: .packedCircles(background: rgb(0.08, 0.08, 0.14),
                                    circles: [rgb(0.96, 0.25, 0.36), rgb(0.99, 0.61, 0.17),
                                              rgb(0.14, 0.73, 0.65), rgb(0.30, 0.45, 0.92),
                                              rgb(0.70, 0.30, 0.86)], seed: 0xC1AC1E),
              ink: .white, text: .white, chip: rgb(0.08, 0.08, 0.14)),

        Theme(id: "delaunay-triangles", name: "Delaunay Triangles",
              style: .triangles([rgb(0.96, 0.32, 0.22), rgb(0.99, 0.62, 0.18), rgb(0.98, 0.84, 0.28),
                                 rgb(0.19, 0.68, 0.62), rgb(0.16, 0.43, 0.68), rgb(0.39, 0.24, 0.59)],
                                seed: 0xDE1A0A7),
              ink: rgb(0.08, 0.08, 0.12), text: rgb(0.10, 0.08, 0.12), chip: rgb(0.98, 0.94, 0.86)),

        Theme(id: "harlequin", name: "Harlequin",
              style: .diamonds(background: rgb(0.08, 0.07, 0.11),
                               diamonds: [rgb(0.93, 0.10, 0.20), rgb(0.98, 0.72, 0.08),
                                          rgb(0.08, 0.56, 0.49), rgb(0.20, 0.30, 0.74)]),
              ink: rgb(0.98, 0.94, 0.82), text: rgb(0.98, 0.94, 0.82), chip: rgb(0.10, 0.09, 0.13)),

        Theme(id: "sunrise", name: "Sunrise",
              style: .gradient([rgb(0.24, 0.18, 0.45), rgb(0.76, 0.30, 0.45), rgb(0.98, 0.52, 0.34),
                                rgb(1.00, 0.79, 0.42), rgb(0.98, 0.92, 0.68)]),
              ink: rgb(0.24, 0.10, 0.16), text: rgb(0.24, 0.10, 0.16), chip: rgb(1.00, 0.90, 0.72)),

        Theme(id: "lavender", name: "Lavender",
              style: .gradient([rgb(0.94, 0.91, 0.98), rgb(0.79, 0.69, 0.91), rgb(0.57, 0.43, 0.76),
                                rgb(0.34, 0.25, 0.52)]),
              ink: rgb(0.20, 0.13, 0.32), text: rgb(0.20, 0.13, 0.32), chip: rgb(0.95, 0.91, 0.98)),

        Theme(id: "fern", name: "Fern",
              style: .triangles([rgb(0.04, 0.18, 0.10), rgb(0.08, 0.30, 0.16), rgb(0.12, 0.44, 0.22),
                                 rgb(0.27, 0.58, 0.30), rgb(0.55, 0.70, 0.38)], seed: 0xFE2A),
              ink: rgb(0.84, 0.93, 0.65), text: rgb(0.88, 0.95, 0.72), chip: rgb(0.05, 0.22, 0.12)),

        Theme(id: "heather", name: "Heather",
              style: .packedCircles(background: rgb(0.19, 0.15, 0.24),
                                    circles: [rgb(0.50, 0.35, 0.58), rgb(0.67, 0.46, 0.68),
                                              rgb(0.78, 0.61, 0.76), rgb(0.38, 0.45, 0.36)],
                                    seed: 0x4EA74E2),
              ink: rgb(0.93, 0.85, 0.91), text: rgb(0.94, 0.88, 0.93), chip: rgb(0.26, 0.19, 0.31)),

        Theme(id: "water", name: "Water",
              style: .waves(background: rgb(0.05, 0.26, 0.43),
                            waves: [rgb(0.10, 0.42, 0.65), rgb(0.16, 0.58, 0.76),
                                    rgb(0.40, 0.76, 0.85), rgb(0.76, 0.91, 0.91)]),
              ink: rgb(0.88, 0.98, 1.00), text: rgb(0.90, 0.98, 1.00), chip: rgb(0.04, 0.29, 0.46)),

        Theme(id: "sparkling-water", name: "Sparkling Water",
              style: .bubbles(background: rgb(0.66, 0.90, 0.91),
                              bubbles: [rgb(0.94, 1.00, 1.00), rgb(0.24, 0.67, 0.72), rgb(0.08, 0.48, 0.58)],
                              seed: 0xBABB1E5),
              ink: rgb(0.04, 0.30, 0.36), text: rgb(0.03, 0.24, 0.29), chip: rgb(0.91, 0.98, 0.97)),

        Theme(id: "supernova", name: "Supernova",
              style: .radial([rgb(1.00, 0.98, 0.72), rgb(1.00, 0.68, 0.16), rgb(0.94, 0.20, 0.17),
                              rgb(0.49, 0.10, 0.46), rgb(0.08, 0.04, 0.19)]),
              ink: .white, text: .white, chip: rgb(0.16, 0.05, 0.20), starSeed: 0x5A9E2A0A),

        Theme(id: "silver", name: "Silver",
              style: .stripes([rgb(0.97, 0.97, 0.98), rgb(0.91, 0.92, 0.94), rgb(0.84, 0.86, 0.89),
                               rgb(0.76, 0.78, 0.82), rgb(0.67, 0.70, 0.75), rgb(0.57, 0.60, 0.66),
                               rgb(0.47, 0.50, 0.56)]),
              ink: rgb(0.10, 0.11, 0.13), text: .black, chip: rgb(0.98, 0.97, 0.95)),
    ]

    static let fallback = all[0]

    static func named(_ id: String?) -> Theme {
        all.first { $0.id == id } ?? fallback
    }

    // MARK: - Persistence
    //
    // The strip's theme and the icon's theme are stored separately, so a Hacker
    // strip can sit under a Sunset icon. By default the icon follows the strip;
    // choosing an icon explicitly breaks the link.

    private static let key = "HostTheme"
    private static let iconKey = "HostIconTheme"
    private static let linkKey = "HostIconFollowsTheme"

    static var current: Theme {
        get { named(UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }

    static var iconFollowsTheme: Bool {
        get { UserDefaults.standard.object(forKey: linkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: linkKey) }
    }

    static var iconTheme: Theme {
        iconFollowsTheme ? current : named(UserDefaults.standard.string(forKey: iconKey))
    }

    static func setIconTheme(_ theme: Theme) {
        UserDefaults.standard.set(theme.id, forKey: iconKey)
        iconFollowsTheme = false
    }

    /// A small sample of how this theme paints the strip, for the settings window.
    func swatch(size: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                   pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bounds = CGRect(origin: .zero, size: size)
        fill(NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6), stripeWidth: 14)
        // A tab card, so the swatch shows what text will actually sit on.
        chip.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: CGRect(x: 8, y: size.height / 2 - 8, width: 44, height: 16),
                     xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
