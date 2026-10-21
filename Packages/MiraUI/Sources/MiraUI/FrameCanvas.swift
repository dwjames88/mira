import AppKit
import MiraCore
import SwiftUI

extension EnvironmentValues {
    /// Draw the canvas with a plain SwiftUI `Image` instead of the IOSurface layer. `ImageRenderer`
    /// cannot capture an `NSView`, so snapshot tests switch this on.
    @Entry var ffImageCanvas = false
}

/// Shows a `PreviewFrame` by handing its IOSurface straight to a Core Animation layer: no CGImage,
/// no NSImage, no per-frame copy. The surface is tagged sRGB, so the window server colour-matches it.
struct FrameCanvas: NSViewRepresentable {
    let frame: PreviewFrame

    func makeNSView(context: Context) -> FrameLayerView { FrameLayerView() }

    func updateNSView(_ view: FrameLayerView, context: Context) {
        view.show(frame)
    }
}

final class FrameLayerView: NSView {
    private var shownID: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.minificationFilterBias = 0
        layer.isOpaque = true
        // A new frame replaces the old one at once; no cross-fade.
        layer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override var isOpaque: Bool { true }

    func show(_ frame: PreviewFrame) {
        guard shownID != frame.id, let layer, let surface = frame.surface else { return }
        shownID = frame.id
        layer.contentsScale = window?.backingScaleFactor ?? layer.contentsScale
        layer.contents = surface
    }
}
