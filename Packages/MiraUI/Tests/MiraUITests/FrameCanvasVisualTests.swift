import AppKit
import MiraCore
import Testing
@testable import MiraUI

/// Opt-in (MIRA_GUI=1): shows a real window with the IOSurface canvas and screenshots it, to check
/// that the layer path colour-matches the CGImage path. Needs a display and screen-capture rights.
@MainActor
@Suite("Frame canvas on screen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MIRA_GUI"] == "1"))
struct FrameCanvasVisualTests {
    @Test func layerMatchesCGImage() async throws {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        model.recipe.filmID = "fuji-velvia-50"
        model.setCanvas(pixels: CGSize(width: 1200, height: 800))
        try await HoverTests.waitFor { model.previewFrame != nil && model.isPreviewIdle }
        let frame = try #require(model.previewFrame)

        let view = FrameLayerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.show(frame)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))

        let out = root.appendingPathComponent("build/snapshots/frame-canvas-window.png")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), out.path]
        try p.run(); p.waitUntilExit()
        window.orderOut(nil)

        let shot = try #require(NSImage(contentsOf: out)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let ref = try #require(frame.cgImage(context: model.engine.context))
        func mean(_ cg: CGImage) -> [Double] {
            let w = 64, h = 43
            var d = [UInt8](repeating: 0, count: w * h * 4)
            d.withUnsafeMutableBytes { buf in
                let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.interpolationQuality = .high
                c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return (0..<3).map { ch in stride(from: ch, to: d.count, by: 4).map { Double(d[$0]) }.reduce(0, +) / Double(w * h) }
        }
        let a = mean(shot), b = mean(ref)
        print("window mean RGB \(a), reference \(b)")
        for c in 0..<3 { #expect(abs(a[c] - b[c]) < 4, "channel \(c): \(a[c]) vs \(b[c])") }
    }
}
