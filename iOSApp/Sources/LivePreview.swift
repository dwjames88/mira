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
            ciContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: true])
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
        // Materialise once so per-frame work is grading only, not a Lanczos over the full source.
        let scaled = renderer.previewImage(from: source, maxPixelSize: wanted)
        let extent = scaled.extent
        if wanted >= sourceLongest {
            proxy = source
        } else if let cg = ciContext.createCGImage(scaled, from: extent, format: .RGBA8, colorSpace: colorSpace) {
            // A bitmap-backed image has no properties: carry the source's EXIF exposure time and headroom over
            // so the reciprocity and exposure stages see them on the proxy too.
            proxy = CIImage(cgImage: cg, options: [.colorSpace: colorSpace])
                .withMiraExposureTime(source.miraExposureTime)
                .withMiraHeadroom(source.miraHeadroom)
        } else {
            proxy = scaled
        }
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
