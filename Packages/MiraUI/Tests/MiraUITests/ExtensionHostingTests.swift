import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Extension hosting", .serialized)
struct ExtensionHostingTests {
    @Test(arguments: [CGSize(width: 1400, height: 900), CGSize(width: 1900, height: 1200), CGSize(width: 1000, height: 700)])
    func editorFillsTheWindowAndFollowsResizes(size: CGSize) async throws {
        FieldFramesTheme.registerFonts()
        let model = try await CropModelTests.makeModel()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 1100, height: 750)),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        // The controller's view: a plain container that autoresizes with its window.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        let host = ExtensionHosting.install(model, in: container)
        #expect(host.sizingOptions.isEmpty)

        window.setContentSize(size)
        container.layoutSubtreeIfNeeded()
        #expect(container.bounds.size == size)
        #expect(host.frame == container.bounds, "host \(host.frame) container \(container.bounds)")

        // Resize again: live resizes are followed.
        window.setContentSize(CGSize(width: size.width - 120, height: size.height - 90))
        container.layoutSubtreeIfNeeded()
        #expect(host.frame == container.bounds)
        window.setContentSize(size)
        container.layoutSubtreeIfNeeded()
        #expect(host.frame == container.bounds)

        // The panel width range leaves the canvas the rest.
        #expect(EditorView<EmptyView>.panelWidth == 300...340)
        model.cancelWork()
    }

    @Test func rootDrawsToTheTopRightCorner() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await CropModelTests.makeModel()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 1000))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = container
        let host = ExtensionHosting.install(model, in: container)
        container.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Top-right and bottom-left corners of the editor are painted (the panel / strip grounds).
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let topRight = try #require(rep.colorAt(x: w - 6, y: 6))
        let bottomLeft = try #require(rep.colorAt(x: 6, y: h - 6))
        #expect(topRight.alphaComponent > 0.99)
        #expect(bottomLeft.alphaComponent > 0.99)
        model.cancelWork()
    }

    @Test func rootFitterFillsSuperviewAndFollowsResizes() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let superview = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 1000))
        superview.autoresizingMask = [.width, .height]
        window.contentView = superview
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        superview.addSubview(root)
        let fitter = ExtensionRootFitter(view: root)
        var hinted: NSSize?
        fitter.onFit = { hinted = $0 }
        fitter.fit(reason: "test")
        superview.layoutSubtreeIfNeeded()
        #expect(root.frame == superview.bounds)
        #expect(hinted == superview.bounds.size)

        window.setContentSize(CGSize(width: 1800, height: 1200))
        superview.layoutSubtreeIfNeeded()
        fitter.fit(reason: "test")
        superview.layoutSubtreeIfNeeded()
        #expect(root.frame == superview.bounds)
        #expect(root.frame.size == CGSize(width: 1800, height: 1200))
    }

    @Test func rootFitterIgnoresAViewWithNoHost() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        let fitter = ExtensionRootFitter(view: root)
        fitter.fit(reason: "test")
        #expect(root.frame.size == CGSize(width: 1100, height: 750))
        #expect(root.translatesAutoresizingMaskIntoConstraints)
    }
}
