#if os(iOS)
import MiraCameraKit
import SwiftUI
import UIKit

/// Hosts the finder's `CAMetalLayer`. Drawing is driven by camera frames, not by a display link or SwiftUI updates.
/// No gestures here; `CameraView` adds them.
public struct FinderView: UIViewRepresentable {
    public let renderer: FinderRenderer

    public init(renderer: FinderRenderer) { self.renderer = renderer }

    public func makeUIView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.renderer = renderer
        renderer.attach(to: view.metalLayer)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Viewfinder"
        view.accessibilityHint = "Double-tap to focus. Touch and hold to see the scene without the film."
        return view
    }

    public func updateUIView(_ view: MetalLayerView, context: Context) {
        if view.renderer !== renderer {
            view.renderer = renderer
            renderer.attach(to: view.metalLayer)
            view.setNeedsLayout()
        }
    }

    public final class MetalLayerView: UIView {
        var renderer: FinderRenderer?

        override public class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            backgroundColor = UIColor(red: 0.082, green: 0.078, blue: 0.059, alpha: 1)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override public func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            guard size.width >= 1, size.height >= 1 else { return }
            metalLayer.contentsScale = scale
            if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
            renderer?.setDrawableSize(size)
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }
}
#endif
