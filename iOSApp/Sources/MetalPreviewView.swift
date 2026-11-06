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
        // A new source (a RAW develop swapping in) changes the picture without changing any property above.
        live.onSourceChange = { [weak view] in view?.setNeedsDisplay() }
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
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            let size = view.drawableSize
            guard size.width >= 1, size.height >= 1,
                  let queue = live.commandQueue,
                  let drawable = view.currentDrawable,
                  let cb = queue.makeCommandBuffer() else { return }
            live.render(into: drawable.texture, commandBuffer: cb, recipe: recipe, cropping: cropping,
                        showingOriginal: showingOriginal, zoom: zoom, offset: offset,
                        contentScale: view.contentScaleFactor, ink: ink)
            cb.present(drawable)
            cb.commit()
        }
    }
}
