import CoreImage
import MetalKit
import MiraCore
import SwiftUI

/// Realtime canvas: every SwiftUI state change renders exactly one frame straight to the drawable.
struct MetalPreviewView: UIViewRepresentable {
    let live: LivePreview
    let recipe: Recipe
    let zoom: CGFloat
    let offset: CGSize
    let showingOriginal: Bool
    let cropping: Bool

    func makeCoordinator() -> Coordinator { Coordinator(live: live) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: live.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0.082, green: 0.078, blue: 0.059, alpha: 1)
        view.backgroundColor = UIColor(red: 0.082, green: 0.078, blue: 0.059, alpha: 1)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        c.recipe = recipe
        c.zoom = zoom
        c.offset = offset
        c.showingOriginal = showingOriginal
        c.cropping = cropping
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let live: LivePreview
        var recipe = Recipe()
        var zoom: CGFloat = 1
        var offset: CGSize = .zero
        var showingOriginal = false
        var cropping = false
        private let ink = CIColor(red: 0.082, green: 0.078, blue: 0.059)

        init(live: LivePreview) { self.live = live }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            live.updateProxyTarget(pixelSize: size, zoom: zoom)
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            let size = view.drawableSize
            guard size.width >= 1, size.height >= 1,
                  let queue = live.commandQueue,
                  let drawable = view.currentDrawable,
                  let cb = queue.makeCommandBuffer() else { return }
            live.updateProxyTarget(pixelSize: size, zoom: zoom)
            let bounds = CGRect(origin: .zero, size: size)
            let space = live.colorSpace
            var output = CIImage(color: ink).cropped(to: bounds)

            if let graded = live.gradedImage(for: recipe, cropping: cropping, showingOriginal: showingOriginal) {
                let e = graded.extent
                if !e.isInfinite, !e.isEmpty, e.width.isFinite, e.height.isFinite {
                    let fit = min(size.width / e.width, size.height / e.height) * max(zoom, 1)
                    let scale = view.contentScaleFactor
                    let w = e.width * fit, h = e.height * fit
                    let tx = (size.width - w) / 2 + offset.width * scale
                    let ty = (size.height - h) / 2 - offset.height * scale
                    var t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
                    t = t.concatenating(CGAffineTransform(scaleX: fit, y: fit))
                    t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
                    // CIContext.render(to: MTLTexture) already maps Core Image bottom-left space
                    // onto the drawable upright; no extra flip (an extra one rendered the photo upside down).
                    output = graded.transformed(by: t).cropped(to: bounds).composited(over: output)
                }
            }
            live.ciContext.render(output, to: drawable.texture, commandBuffer: cb, bounds: bounds, colorSpace: space)
            cb.present(drawable)
            cb.commit()
        }
    }
}
