import AppKit

// Renders the AutoDuck app icon (1024×1024): teal rounded square, flat yellow duck quacking
// soundwaves at a white volume-down symbol. Output is packed into AppIcon.icns by make-icon.sh.
let size = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

// --- Background tile: rounded square, muted teal, subtle depth
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor.black.withAlphaComponent(0.28).cgColor)
rgb(96, 168, 160).setFill()
tilePath.fill()
ctx.restoreGState()
let grad = NSGradient(colors: [rgb(138, 204, 196), rgb(86, 160, 152)])!
ctx.saveGState()
tilePath.addClip()
grad.draw(in: tile, angle: -90)
// soft highlight in the upper area
let hl = NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0), 0.0),
                                        (NSColor.white.withAlphaComponent(0), 0.45),
                                        (NSColor.white.withAlphaComponent(0.16), 1.0))!
hl.draw(in: tile, angle: 90)
ctx.restoreGState()

// --- Duck (left), flat & minimalist
let yellow = rgb(250, 205, 70)
let orange = rgb(240, 138, 58)
let ink = rgb(46, 46, 50)

// body
yellow.setFill()
NSBezierPath(ovalIn: NSRect(x: 150, y: 250, width: 400, height: 260)).fill()
// tail tip
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 200, y: 380))
tail.curve(to: NSPoint(x: 125, y: 470), controlPoint1: NSPoint(x: 160, y: 400), controlPoint2: NSPoint(x: 120, y: 430))
tail.curve(to: NSPoint(x: 230, y: 470), controlPoint1: NSPoint(x: 150, y: 500), controlPoint2: NSPoint(x: 200, y: 495))
tail.close(); tail.fill()
// head
NSBezierPath(ovalIn: NSRect(x: 220, y: 420, width: 310, height: 310)).fill()
// wing (slightly darker yellow)
rgb(236, 186, 52).setFill()
NSBezierPath(ovalIn: NSRect(x: 210, y: 300, width: 220, height: 120)).fill()
// open beak: upper and lower bills
orange.setFill()
let upper = NSBezierPath()
upper.move(to: NSPoint(x: 500, y: 600))
upper.line(to: NSPoint(x: 650, y: 625))
upper.curve(to: NSPoint(x: 640, y: 575), controlPoint1: NSPoint(x: 690, y: 620), controlPoint2: NSPoint(x: 690, y: 580))
upper.line(to: NSPoint(x: 505, y: 560))
upper.close(); upper.fill()
let lower = NSBezierPath()
lower.move(to: NSPoint(x: 505, y: 545))
lower.line(to: NSPoint(x: 630, y: 520))
lower.curve(to: NSPoint(x: 620, y: 470), controlPoint1: NSPoint(x: 670, y: 515), controlPoint2: NSPoint(x: 665, y: 470))
lower.line(to: NSPoint(x: 500, y: 505))
lower.close(); lower.fill()
// mouth interior
rgb(200, 95, 60).setFill()
let mouth = NSBezierPath()
mouth.move(to: NSPoint(x: 505, y: 560)); mouth.line(to: NSPoint(x: 640, y: 575)); mouth.line(to: NSPoint(x: 630, y: 520)); mouth.line(to: NSPoint(x: 505, y: 545)); mouth.close(); mouth.fill()
// eye (dot) + tiny highlight
ink.setFill()
NSBezierPath(ovalIn: NSRect(x: 430, y: 600, width: 40, height: 40)).fill()
NSColor.white.withAlphaComponent(0.9).setFill()
NSBezierPath(ovalIn: NSRect(x: 448, y: 622, width: 12, height: 12)).fill()

// --- Soundwaves from the beak
let waveCenter = NSPoint(x: 650, y: 560)
for (i, r) in [75.0, 125.0, 175.0].enumerated() {
    let p = NSBezierPath()
    p.appendArc(withCenter: waveCenter, radius: CGFloat(r), startAngle: -34, endAngle: 34)
    p.lineWidth = 26
    p.lineCapStyle = .round
    NSColor.white.withAlphaComponent([0.95, 0.75, 0.55][i]).setStroke()
    p.stroke()
}

// --- Volume-down symbol (right), pushed downward
NSColor.white.setFill()
NSColor.white.setStroke()
// speaker
let spk = NSBezierPath()
spk.move(to: NSPoint(x: 705, y: 385)); spk.line(to: NSPoint(x: 752, y: 385)); spk.line(to: NSPoint(x: 830, y: 445))
spk.line(to: NSPoint(x: 830, y: 245)); spk.line(to: NSPoint(x: 752, y: 305)); spk.line(to: NSPoint(x: 705, y: 305)); spk.close()
spk.lineJoinStyle = .round; spk.lineWidth = 14; spk.stroke(); spk.fill()
// down arrow
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 768, y: 222)); arrow.line(to: NSPoint(x: 768, y: 160))
arrow.move(to: NSPoint(x: 726, y: 198)); arrow.line(to: NSPoint(x: 768, y: 156)); arrow.line(to: NSPoint(x: 810, y: 198))
arrow.lineWidth = 30; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
