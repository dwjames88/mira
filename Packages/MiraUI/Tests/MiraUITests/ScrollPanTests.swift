import AppKit
import CoreGraphics
import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("Scroll pan", .serialized)
struct ScrollPanTests {
    @Test func scrollEventPansZoomedPicture() async throws {
        let (model, _) = try await HoverTests.makeModel()
        model.setViewport(pane: CGSize(width: 800, height: 600), fitArea: CGSize(width: 760, height: 560))
        #expect(model.canZoom)
        model.zoomClick(atPane: CGPoint(x: 400, y: 300))
        #expect(!model.zoom.isFit)

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = TrackpadMonitorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.model = model
        view.backingScale = 2
        window.contentView?.addSubview(view)

        // Screen point at the view's centre, converted to CG global (top-left) coordinates.
        let primary = try #require(NSScreen.screens.first)
        let inWindow = view.convert(NSPoint(x: 200, y: 150), to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let cgPoint = CGPoint(x: screen.x, y: primary.frame.height - screen.y)

        func scroll(at p: CGPoint) throws -> TrackpadMonitorView.Input {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: -30, wheel2: -20, wheel3: 0))
            cg.location = p
            let ns = try #require(NSEvent(cgEvent: cg))
            return TrackpadMonitorView.Input(event: ns)
        }

        let before = model.zoom.center
        #expect(view.handle(try scroll(at: cgPoint)))
        #expect(model.zoom.center != before)

        // Outside the view: untouched.
        let mid = model.zoom.center
        #expect(!view.handle(try scroll(at: CGPoint(x: cgPoint.x + 2000, y: cgPoint.y))))
        #expect(model.zoom.center == mid)
    }
}
