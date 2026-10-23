import AppKit
import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// The transparent layer over the picture while the dodge and burn tool is open. It takes the drags
/// (painting, or panning when Space is held on a zoomed picture), reads tablet pressure, and draws
/// the brush as a ring: the outline is the brush on screen, the inner ring is where the feather
/// starts. A real `NSView` rather than a SwiftUI gesture, because only an event has `pressure`.
struct DodgeBurnPaintLayer: NSViewRepresentable {
    let model: EditorModel
    let scale: CGFloat

    func makeNSView(context: Context) -> DodgeBurnPaintView { DodgeBurnPaintView() }

    func updateNSView(_ view: DodgeBurnPaintView, context: Context) {
        view.model = model
        view.backingScale = scale
        // Reading these here registers them, so the ring follows the brush and the zoom.
        let tool = model.dodgeBurnTool
        _ = (tool.brush.size, tool.brush.feather, tool.brush.mode, tool.isFlipping, model.zoom, model.recipe.crop)
        view.needsDisplay = true
    }
}

@MainActor
final class DodgeBurnPaintView: NSView {
    weak var model: EditorModel?
    var backingScale: CGFloat = 2
    private var pointer: CGPoint?
    private var panning = false
    private var lastPan = CGPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Events

    /// A tablet reports pressure; a mouse or trackpad paints at full pressure.
    private func pressure(_ event: NSEvent) -> Double {
        event.subtype == .tabletPoint ? Double(event.pressure) : 1
    }

    private func paneDeviceLocation(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x * backingScale, y: p.y * backingScale)
    }

    private func track(_ event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        model?.setPaintFlipping(event.modifierFlags.contains(.option))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        track(event)
        let p = paneDeviceLocation(event)
        if model.isSpaceHeld, !model.zoom.isFit {
            panning = true
            lastPan = p
            return
        }
        model.beginPaintStroke(atPane: p, pressure: pressure(event), flipped: event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        track(event)
        let p = paneDeviceLocation(event)
        if panning {
            model.zoomPan(byPane: CGSize(width: p.x - lastPan.x, height: p.y - lastPan.y))
            lastPan = p
            return
        }
        model.continuePaintStroke(atPane: p, pressure: pressure(event))
    }

    override func mouseUp(with event: NSEvent) {
        panning = false
        model?.endPaintStroke()
    }

    override func flagsChanged(with event: NSEvent) {
        model?.setPaintFlipping(event.modifierFlags.contains(.option))
        needsDisplay = true
    }

    // MARK: Brush ring

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let pointer, let ring = BrushRing(model: model, scale: backingScale) else { return }
        let c = pointer
        func circle(_ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        let shade = NSColor.black.withAlphaComponent(0.45)
        let line = NSColor(ring.color)
        let outer = circle(ring.radius)
        let halo = circle(ring.radius + 1)
        shade.setStroke()
        halo.lineWidth = 1
        halo.stroke()
        line.setStroke()
        outer.lineWidth = 1
        outer.stroke()
        if ring.innerRadius > 2 {
            let inner = circle(ring.innerRadius)
            inner.lineWidth = 1
            inner.setLineDash([3, 3], count: 2, phase: 0)
            line.withAlphaComponent(0.8).setStroke()
            inner.stroke()
        }
        // A cross at the centre: plus for dodge, minus for burn, an x for erase.
        let arm: CGFloat = 4
        let glyph = NSBezierPath()
        if ring.mode != .erase {
            glyph.move(to: CGPoint(x: c.x - arm, y: c.y)); glyph.line(to: CGPoint(x: c.x + arm, y: c.y))
        }
        if ring.mode == .dodge {
            glyph.move(to: CGPoint(x: c.x, y: c.y - arm)); glyph.line(to: CGPoint(x: c.x, y: c.y + arm))
        }
        if ring.mode == .erase {
            glyph.move(to: CGPoint(x: c.x - arm, y: c.y - arm)); glyph.line(to: CGPoint(x: c.x + arm, y: c.y + arm))
            glyph.move(to: CGPoint(x: c.x - arm, y: c.y + arm)); glyph.line(to: CGPoint(x: c.x + arm, y: c.y - arm))
        }
        glyph.lineWidth = 1.5
        shade.setStroke()
        glyph.transform(using: AffineTransform(translationByX: 0.5, byY: 0.5))
        glyph.stroke()
        glyph.transform(using: AffineTransform(translationByX: -0.5, byY: -0.5))
        line.setStroke()
        glyph.stroke()
    }
}

/// What the brush ring looks like for the current brush and zoom, in points.
struct BrushRing {
    let radius: CGFloat
    let innerRadius: CGFloat
    let mode: DodgeBurnMode
    let color: Color

    @MainActor
    init?(model: EditorModel, scale: CGFloat) {
        let brush = model.dodgeBurnTool.brush
        guard let device = model.brushRadiusInPane(size: brush.size) else { return nil }
        radius = max(2, device / max(scale, 1))
        innerRadius = radius * CGFloat(1 - min(max(brush.feather, 0), 1))
        mode = model.effectiveBrushMode
        switch mode {
        case .dodge: color = T.onPhoto
        case .burn: color = T.onPhotoAccent
        case .erase: color = T.onPhotoDim
        }
    }
}
