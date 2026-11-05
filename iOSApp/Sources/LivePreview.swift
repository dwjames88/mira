import CoreImage
import Metal
import MiraCore

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
    private var proxyLongSide: CGFloat = 0

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
        proxyLongSide = 0
    }

    /// (Re)builds the proxy for the on-screen drawable. Rebuilds only when it must grow by >25%.
    func updateProxyTarget(pixelSize: CGSize, zoom: CGFloat) {
        guard let source, let renderer else { return }
        let drawable = max(pixelSize.width, pixelSize.height)
        guard drawable > 0, drawable.isFinite else { return }
        let sourceLongest = max(source.extent.width, source.extent.height)
        let wanted = min(sourceLongest, max(drawable, drawable * max(zoom, 1)).rounded(.up))
        if proxy != nil, wanted <= proxyLongSide * 1.25 { return }
        // Materialise once so per-frame work is grading only, not a Lanczos over the full source. The proxy keeps
        // the source's range (half-float, extended linear) and its headroom tag: see `PreviewProxy`.
        proxy = PreviewProxy.make(from: source, renderer: renderer, context: ciContext, wanted: wanted)
        proxyLongSide = wanted
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
}
