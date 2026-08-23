import AppKit

/// The menu-bar mascot: a minimalist duck head wearing headphones, drawn as a vector template
/// image so it adapts to light/dark menu bars.
///
/// - `.resting`  — dot eye: listening, music playing normally
/// - `.sleeping` — closed "U" eye + a little z: music is resting (ducked)
/// - `.paused`   — faded duck: Mr. AutoDuck is switched off
enum DuckIcon {
    enum Style: Equatable { case resting, sleeping, paused }

    static let pointSize = NSSize(width: 20, height: 18)

    static func image(_ style: Style) -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            draw(style, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws in a 20×18 point coordinate space, origin bottom-left, y up.
    static func draw(_ style: Style, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let ink = NSColor.black
        ink.setFill()
        ink.setStroke()

        // Head
        let headCenter = NSPoint(x: 7.2, y: 7.4)
        let headRadius: CGFloat = 5.4
        NSBezierPath(ovalIn: NSRect(x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                                    width: headRadius * 2, height: headRadius * 2)).fill()

        // Beak (facing right): a flat bill, sitting below the ear cup
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: 10.6, y: 7.6))
        beak.line(to: NSPoint(x: 15.4, y: 6.9))
        beak.curve(to: NSPoint(x: 15.4, y: 3.9),
                   controlPoint1: NSPoint(x: 17.6, y: 6.8), controlPoint2: NSPoint(x: 17.6, y: 4.0))
        beak.line(to: NSPoint(x: 10.6, y: 3.7))
        beak.close()
        beak.fill()

        // Headphones: band clearly above the head, ear cups bridging band and head
        let bandRadius = headRadius + 2.3
        let band = NSBezierPath()
        band.appendArc(withCenter: headCenter, radius: bandRadius, startAngle: 8, endAngle: 172)
        band.lineWidth = 1.6
        band.lineCapStyle = .round
        band.stroke()
        for angle in [CGFloat(8), CGFloat(172)] {
            let r = headRadius + 1.0
            let p = NSPoint(x: headCenter.x + r * cos(angle * .pi / 180), y: headCenter.y + r * sin(angle * .pi / 180))
            NSBezierPath(roundedRect: NSRect(x: p.x - 1.4, y: p.y - 2.6, width: 2.8, height: 4.4),
                         xRadius: 1.2, yRadius: 1.2).fill()
        }

        // Eye — cut out of the silhouette so it reads as an eye in any menu-bar colour
        ctx.saveGraphicsState()
        ctx.compositingOperation = .destinationOut
        switch style {
        case .resting, .paused:
            NSBezierPath(ovalIn: NSRect(x: 8.0, y: 8.2, width: 2.2, height: 2.2)).fill()
        case .sleeping:
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 7.7, y: 9.9))
            eye.curve(to: NSPoint(x: 10.5, y: 9.9),
                      controlPoint1: NSPoint(x: 8.0, y: 8.1), controlPoint2: NSPoint(x: 10.2, y: 8.1))
            eye.lineWidth = 1.2
            eye.lineCapStyle = .round
            eye.stroke()
        }
        ctx.restoreGraphicsState()

        // A little "z" when the music is resting
        if style == .sleeping {
            let z = NSBezierPath()
            z.move(to: NSPoint(x: 15.2, y: 15.8))
            z.line(to: NSPoint(x: 18.4, y: 15.8))
            z.line(to: NSPoint(x: 15.2, y: 12.6))
            z.line(to: NSPoint(x: 18.4, y: 12.6))
            z.lineWidth = 1.3
            z.lineCapStyle = .round
            z.lineJoinStyle = .round
            z.stroke()
        }

        // Paused: fade the whole drawing uniformly (not shape by shape, which would show seams)
        if style == .paused {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationIn
            NSColor.black.withAlphaComponent(0.4).setFill()
            rect.fill()
            ctx.restoreGraphicsState()
        }
    }
}
