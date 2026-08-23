import AppKit
import SwiftUI

/// Developer tool: `open -n -W "build/Mr. AutoDuck.app" --args --render-docs /abs/output/dir`
/// Renders the real popover UI with representative values to PNG files for the README.
/// Uses an off-screen window + `cacheDisplay` so AppKit-backed controls (sliders, toggles) render.
enum DocsRenderer {
    static var isActive: Bool { CommandLine.arguments.contains("--render-docs") }

    @MainActor
    static func run() {
        guard let dirArg = CommandLine.arguments.last, dirArg.hasPrefix("/") else {
            Log.app.error("--render-docs needs an absolute output directory")
            return
        }
        let dir = URL(fileURLWithPath: dirArg, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared

        model.applyDemoState(listening: true)
        render(model, name: "popover-listening", dark: false, to: dir)
        model.applyDemoState(listening: false)
        render(model, name: "popover-ducked", dark: false, to: dir)
        render(model, name: "popover-ducked-dark", dark: true, to: dir)
        Log.app.info("Rendered docs images to \(dir.path, privacy: .public)")
    }

    @MainActor
    private static func render(_ model: AppModel, name: String, dark: Bool, to dir: URL) {
        let root = MenuView()
            .environmentObject(model)
            .environmentObject(model.settings)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // On-screen (briefly) so Core Animation actually runs — NSSwitch only moves its knob when the
        // window is visible. It's a borderless window at the bottom-left corner for ~1.5 s.
        let window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.level = .floating
        window.makeKeyAndOrderFront(nil)   // note: a background-launched app can't become active, so
                                           // controls render in their (untinted) inactive style
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let bounds = hosting.bounds
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            window.close()
            return
        }
        let cg = gctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Render the committed Core Animation layer tree (includes AppKit controls as displayed).
        if let layer = hosting.layer {
            // CALayer.render(in:) draws in a flipped coordinate system relative to the view.
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            layer.render(in: cg)
        } else {
            hosting.cacheDisplay(in: bounds, to: rep)
        }
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// Borderless windows refuse key status by default, which makes AppKit draw controls untinted.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
