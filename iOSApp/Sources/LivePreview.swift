import CoreImage
import Metal
import MiraCore
import UIKit

/// GPU-resident preview state. Main-actor confined; built once and reused for every frame.
@MainActor
final class LivePreview {
    let device: MTLDevice?
    let ciContext: CIContext
    let renderer: Renderer?

    private(set) var source: CIImage?
    private(set) var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var sourceSize: CGSize = .zero
    /// Downscaled, materialised copy of the source used for interactive rendering.
    private(set) var proxy: CIImage?
    private(set) var builtLongSide: CGFloat = 0

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        device = dev
        if let dev, let queue = dev.makeCommandQueue() {
            commandQueue = queue
            ciContext = Renderer.makeContext(commandQueue: queue)
        } else {
            commandQueue = nil
            ciContext = Renderer.sharedContext
        }
        renderer = FilmLibrary.bundled(in: .main).map { Renderer(library: $0) }
    }

    let commandQueue: MTLCommandQueue?

    func setSource(_ image: CIImage, colorSpace: CGColorSpace, size: CGSize) {
        source = image
        self.colorSpace = colorSpace
        sourceSize = size
        proxy = nil
        builtLongSide = 0
        epoch += 1
        stageKey = nil
    }

    /// The pixel box the proxy is sized for: the screen's native pixels, the largest the photo can ever be
    /// drawn into. Fixed per device, so the graded pixels never depend on which step (and so which photo
    /// rect) is showing. Tests inject their own.
    var proxyBox: CGSize = LivePreview.screenBox

    static var screenBox: CGSize {
        let b = UIScreen.main.nativeBounds.size
        return CGSize(width: min(b.width, b.height), height: max(b.width, b.height))
    }

    /// The proxy's long side for `zoom`: the source aspect-fitted into `proxyBox`, doubled per zoom level
    /// (zoom 1 = 1x, 2 = 2x, 3...4 = 4x, ...), never beyond the source. Pure in (source, box, zoom), so the look
    /// is the same however the user got here.
    func proxyLongSide(zoom: CGFloat) -> CGFloat {
        guard let source else { return 0 }
        let e = source.extent
        guard e.width > 0, e.height > 0, proxyBox.width > 0, proxyBox.height > 0 else { return 0 }
        let fit = min(proxyBox.width / e.width, proxyBox.height / e.height)
        let level = exp2(ceil(log2(max(zoom, 1))))
        return min(max(e.width, e.height), (max(e.width, e.height) * fit * level).rounded(.up))
    }

    /// (Re)builds the proxy for `zoom` when its size level changed (up or down); a no-op otherwise.
    /// The drawable size plays no part: the photo is drawn from the same graded pixels in every step.
    func updateProxyTarget(zoom: CGFloat) {
        guard let source, let renderer else { return }
        let wanted = proxyLongSide(zoom: zoom)
        guard wanted > 0 else { return }
        if proxy != nil, wanted == builtLongSide { return }
        // Materialise once so per-frame work is grading only, not a Lanczos over the full source. The proxy keeps
        // the source's range (half-float, extended linear) and its headroom tag: see `PreviewProxy`.
        proxy = PreviewProxy.make(from: source, renderer: renderer, context: ciContext, wanted: wanted)
        builtLongSide = wanted
        epoch += 1
    }

    /// Pure: the image to show for `recipe`. While `cropping`, the crop rect is dropped so the
    /// rotated/flipped/straightened full frame is shown (the crop overlay maps against it).
    func gradedImage(for recipe: Recipe, cropping: Bool, showingOriginal: Bool) -> CIImage? {
        guard let proxy, let renderer else { return proxy }
        var r = recipe
        if cropping { r.crop = recipe.crop.withFullRect }
        if showingOriginal {
            let plain = Recipe(crop: r.crop)
            return CropGeometry.apply(plain.crop, to: proxy)
        }
        // The proxy is a downscaled source: tell the grain stage how far, so it matches the full-resolution look.
        let scale = source.map { min(1, proxy.extent.width / max($0.extent.width, 1)) } ?? 1
        return renderer.withPreviewScale(scale).apply(r, to: proxy)
    }

    /// The frame for the lazy graph: `gradedImage` fitted (and zoomed / panned) into a drawable of `size` pixels
    /// over the ground colour. `contentScale` is the view's pixels per point (the pan offset is in points).
    func frame(for recipe: Recipe, cropping: Bool, showingOriginal: Bool, size: CGSize, zoom: CGFloat,
               offset: CGSize, contentScale: CGFloat, ink: CIColor) -> CIImage {
        updateProxyTarget(zoom: zoom)
        return place(gradedImage(for: recipe, cropping: cropping, showingOriginal: showingOriginal),
                     size: size, zoom: zoom, offset: offset, contentScale: contentScale, ink: ink)
    }

    /// Pure placement of an already graded picture in a drawable of `size` pixels.
    func place(_ graded: CIImage?, size: CGSize, zoom: CGFloat, offset: CGSize, contentScale: CGFloat,
               ink: CIColor) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var output = CIImage(color: ink).cropped(to: bounds)
        guard let graded else { return output }
        let e = graded.extent
        guard !e.isInfinite, !e.isEmpty, e.width.isFinite, e.height.isFinite else { return output }
        let fit = min(size.width / e.width, size.height / e.height) * max(zoom, 1)
        let w = e.width * fit, h = e.height * fit
        let tx = (size.width - w) / 2 + offset.width * contentScale
        let ty = (size.height - h) / 2 - offset.height * contentScale
        var t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
        t = t.concatenating(CGAffineTransform(scaleX: fit, y: fit))
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        // CIContext.render(to: MTLTexture) already maps Core Image bottom-left space onto the drawable upright.
        output = graded.transformed(by: t).cropped(to: bounds).composited(over: output)
        return output
    }

    // MARK: Staged grade

    /// What the staged texture holds the grade of.
    private struct StageKey: Equatable {
        var recipe: Recipe
        var cropping: Bool
        var showingOriginal: Bool
        var epoch: Int
        var longSide: CGFloat
    }

    private var stage: MTLTexture?
    private var stageKey: StageKey?
    private var stageOrigin: CGPoint = .zero
    /// Bumped whenever the proxy pixels change (new source, rebuilt proxy).
    private var epoch = 0
    /// The linear working space the stage is kept in: exactly the context's own, so no conversion touches it.
    private static let stageSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Draws the whole preview (grade, then placement) into `target` through `commandBuffer`.
    ///
    /// At 1x the grade is rendered ONCE into a half-float texture of the proxy's own size, whatever the
    /// drawable is, and the drawable only resamples that texture. So the graded pixels depend on the recipe and
    /// the proxy alone: not on the drawable size, its offset in the window or Core Image's tiling of a partial
    /// destination (the look is the same in every editor step, which give the photo rects of different size).
    /// Pan and zoom redraws reuse the texture. Zoomed in (proxy beyond the screen) the graph renders lazily
    /// into the visible part only, as before.
    func render(into target: MTLTexture, commandBuffer: MTLCommandBuffer, recipe: Recipe, cropping: Bool,
                showingOriginal: Bool, zoom: CGFloat, offset: CGSize, contentScale: CGFloat, ink: CIColor) {
        let size = CGSize(width: target.width, height: target.height)
        let bounds = CGRect(origin: .zero, size: size)
        updateProxyTarget(zoom: zoom)
        guard let graded = gradedImage(for: recipe, cropping: cropping, showingOriginal: showingOriginal) else {
            ciContext.render(place(nil, size: size, zoom: zoom, offset: offset, contentScale: contentScale, ink: ink),
                             to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
            return
        }
        var picture = graded
        if zoom <= 1, let staged = stagedImage(graded, recipe: recipe, cropping: cropping,
                                               showingOriginal: showingOriginal, commandBuffer: commandBuffer) {
            picture = staged
        }
        ciContext.render(place(picture, size: size, zoom: zoom, offset: offset, contentScale: contentScale, ink: ink),
                         to: target, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
    }

    private func stagedImage(_ graded: CIImage, recipe: Recipe, cropping: Bool, showingOriginal: Bool,
                             commandBuffer: MTLCommandBuffer) -> CIImage? {
        let e = graded.extent
        guard let device, !e.isInfinite, !e.isEmpty, e.width.isFinite, e.height.isFinite else { return nil }
        let box = e.integral
        let w = Int(box.width), h = Int(box.height)
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
        let key = StageKey(recipe: recipe, cropping: cropping, showingOriginal: showingOriginal, epoch: epoch,
                           longSide: builtLongSide)
        if stage?.width != w || stage?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            stage = device.makeTexture(descriptor: d)
            stageKey = nil
        }
        guard let stage else { return nil }
        if stageKey != key {
            ciContext.render(graded, to: stage, commandBuffer: commandBuffer, bounds: box, colorSpace: Self.stageSpace)
            stageKey = key
            stageOrigin = box.origin
        }
        guard let image = CIImage(mtlTexture: stage, options: [.colorSpace: Self.stageSpace]) else { return nil }
        // A texture's row 0 is the top; Core Image's origin is the bottom-left.
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: stageOrigin.x, y: stageOrigin.y))
    }
}
