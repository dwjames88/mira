import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import IOSurface

/// One rendered preview: an IOSurface-backed BGRA8 pixel buffer tagged sRGB, ready to be used as
/// the contents of a `CALayer` without any CGImage round trip.
public struct PreviewFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Increases with every rendered frame.
    public let id: Int
    /// Where a zoomed frame sits in the picture; nil for a frame that shows the whole picture.
    public let placement: ZoomPlacement?

    public init(pixelBuffer: CVPixelBuffer, id: Int, placement: ZoomPlacement? = nil) {
        self.pixelBuffer = pixelBuffer
        self.id = id
        self.placement = placement
    }

    /// The part of the picture this frame shows, in picture pixels (the cropped output with its
    /// border). A frame of the whole picture covers `[0, whole]`.
    public func contentRect(whole: CGSize) -> CGRect {
        guard let placement else { return CGRect(origin: .zero, size: whole) }
        let s = CGFloat(placement.scale)
        return CGRect(x: placement.origin.x / s, y: placement.origin.y / s,
                      width: pixelSize.width / s, height: pixelSize.height / s)
    }

    public var pixelSize: CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    public var surface: IOSurfaceRef? { CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() }

    /// A CGImage copy of the frame (snapshots, tests, tiny hover chips); not used for the canvas.
    public func cgImage(context: CIContext) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: srgb])
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)
    }
}

/// Where a zoomed frame sits: its scale (frame pixels per picture pixel) and the position of its top
/// left corner in scaled picture pixels (picture pixels x scale).
public struct ZoomPlacement: Equatable, Sendable {
    public let scale: Double
    public let origin: CGPoint

    public init(scale: Double, origin: CGPoint) {
        self.scale = scale
        self.origin = origin
    }
}

/// Renders interactive previews at canvas resolution.
///
/// The expensive, slider-independent part (crop, rotation, straighten and the downscale to canvas
/// size) is done once per (source, crop, size) and kept as a half-float bitmap; a slider change
/// then only runs the grading graph on that small bitmap. The crop is applied to the best
/// matching level of a power-of-two pyramid of the source, so a tight crop of a 24 MP photo reads
/// only the pixels it needs and stays sharp, while the whole picture at canvas size reads a small
/// level. Thread safe: renders can run on several queues at once.
public final class PreviewEngine: @unchecked Sendable {
    public let renderer: Renderer
    public let context: CIContext

    private let lock = NSLock()
    private var source: CIImage?
    private var generation = 0
    private var levels: [Int: CIImage] = [:]
    private var bases: [BaseKey: CIImage] = [:]
    private var baseOrder: [BaseKey] = []
    private var zoomBases: [ZoomBaseKey: CIImage] = [:]
    private var zoomBaseOrder: [ZoomBaseKey] = []
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private var poolOrder: [PoolKey] = []
    private var frameCounter = 0

    private struct BaseKey: Hashable {
        let generation: Int
        let crop: CropSettings
        let width: Int
        let height: Int
    }

    private struct ZoomBaseKey: Hashable {
        let generation: Int
        let crop: CropSettings
        /// Scale in thousandths.
        let scale: Int
    }

    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let format: OSType
    }

    /// Parallel thumbnail renders; the first run also decodes film LUTs, which parallelises well.
    public static let defaultThumbnailWorkers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))

    private static let baseLimit = 6
    private static let zoomBaseLimit = 3
    private static let maxLevel = 6

    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(renderer: Renderer, context: CIContext) {
        self.renderer = renderer
        self.context = context
    }

    // MARK: Source

    /// Replaces the source (origin is moved to zero). Cached bases and pyramid levels are dropped.
    @discardableResult
    public func setSource(_ image: CIImage?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let e = image?.extent
        if let image, let e, !e.isInfinite, !e.isEmpty {
            source = e.origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        } else {
            source = nil
        }
        levels = [:]
        bases = [:]
        baseOrder = []
        zoomBases = [:]
        zoomBaseOrder = []
        return generation
    }

    public var sourceGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public var hasSource: Bool {
        lock.lock(); defer { lock.unlock() }
        return source != nil
    }

    public var sourceSize: CGSize? {
        lock.lock(); defer { lock.unlock() }
        return source?.extent.size
    }

    private func snapshot() -> (CIImage, Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let source else { return nil }
        return (source, generation)
    }

    // MARK: Frames

    /// Renders `recipe` at canvas resolution (`canvas` in pixels, nil for the fallback size).
    public func render(_ recipe: Recipe, canvas: CGSize?) -> PreviewFrame? {
        Perf.interval("preview render") {
            guard let base = previewBase(crop: recipe.crop, canvas: canvas) else { return nil }
            let graded = renderer.grade(recipe, cropped: base)
            return renderFrame(graded)
        }
    }

    /// The untouched picture (only the recipe's crop applied), for press-and-hold compare.
    public func renderOriginal(crop: CropSettings, canvas: CGSize?) -> PreviewFrame? {
        render(Recipe(crop: crop), canvas: canvas)
    }

    private func renderFrame(_ image: CIImage, from region: CGRect? = nil, placement: ZoomPlacement? = nil) -> PreviewFrame? {
        let extent = region ?? image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        guard let buffer = makeBuffer(width: w, height: h, format: kCVPixelFormatType_32BGRA) else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = Self.srgbSpace
        do {
            let task = try context.startTask(toRender: image, from: extent, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch {
            return nil
        }
        Self.tag(buffer, Self.srgbSpace)
        lock.lock()
        frameCounter += 1
        let id = frameCounter
        lock.unlock()
        return PreviewFrame(pixelBuffer: buffer, id: id, placement: placement)
    }

    // MARK: Bases

    /// The cropped picture scaled to the size `canvas` calls for, as a small bitmap.
    public func previewBase(crop: CropSettings, canvas: CGSize?) -> CIImage? {
        guard let (source, generation) = snapshot() else { return nil }
        let content = CropGeometry.outputExtent(for: crop, imageExtent: source.extent).size
        let size = PreviewSizing.renderSize(content: content, canvas: canvas)
        let key = BaseKey(generation: generation, crop: crop, width: Int(size.width), height: Int(size.height))
        lock.lock()
        if let hit = bases[key] {
            baseOrder.removeAll { $0 == key }
            baseOrder.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let image = buildBase(source: source, generation: generation, crop: crop, content: content, size: size)
        lock.lock()
        if self.generation == generation, let image {
            bases[key] = image
            baseOrder.removeAll { $0 == key }
            baseOrder.append(key)
            while baseOrder.count > Self.baseLimit { bases[baseOrder.removeFirst()] = nil }
        }
        lock.unlock()
        return image
    }

    private func buildBase(source: CIImage, generation: Int, crop: CropSettings, content: CGSize, size: CGSize) -> CIImage? {
        // Pick the coarsest pyramid level that still has at least one pixel per output pixel.
        let ratio = size.width / max(content.width, 1)
        var level = 0
        while level < Self.maxLevel, 1 / Double(1 << (level + 1)) >= ratio * 0.999 { level += 1 }
        let input = self.level(level, source: source, generation: generation)
        guard let input else { return nil }
        var cropped = CropGeometry.apply(crop, to: input)
        let e = cropped.extent
        if abs(e.width - size.width) > 0.5 || abs(e.height - size.height) > 0.5 {
            cropped = Self.resample(cropped, to: size)
        }
        return materialise(cropped)
    }

    /// Level `k` is the source scaled by 1/2^k, materialised as a half-float bitmap.
    private func level(_ k: Int, source: CIImage, generation: Int) -> CIImage? {
        if k == 0 { return source }
        lock.lock()
        if self.generation == generation, let hit = levels[k] { lock.unlock(); return hit }
        lock.unlock()
        guard let parent = level(k - 1, source: source, generation: generation) else { return nil }
        let e = parent.extent
        let target = CGSize(width: max(1, (e.width / 2).rounded(.up)), height: max(1, (e.height / 2).rounded(.up)))
        guard let image = materialise(Self.resample(parent, to: target)) else { return nil }
        lock.lock()
        if self.generation == generation { levels[k] = image }
        lock.unlock()
        return image
    }

    /// Lanczos resize to exactly `size` (origin zero), replicating the edges so borders stay opaque.
    static func resample(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        let moved = e.origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sy = size.height / e.height
        let sx = size.width / e.width
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = moved.clampedToExtent()
        f.scale = Float(sy)
        f.aspectRatio = Float(sx / sy)
        let out = f.outputImage ?? moved
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Renders `image` once into a half-float IOSurface buffer in the working space and wraps it.
    private func materialise(_ image: CIImage) -> CIImage? {
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty else { return nil }
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        guard let buffer = makeBuffer(width: w, height: h, format: kCVPixelFormatType_64RGBAHalf) else { return nil }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = Self.linearSpace
        do {
            let task = try context.startTask(toRender: image, from: e, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        } catch {
            return nil
        }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.linearSpace])
    }

    // MARK: Zoomed frames

    /// The size of the whole picture as the canvas shows it for `recipe`: the cropped output plus the
    /// border (the same size `ZoomGeometry` works in).
    public static func zoomContentSize(for recipe: Recipe, imageSize: CGSize) -> CGSize {
        let size = CropGeometry.outputExtent(for: recipe.crop, imageExtent: CGRect(origin: .zero, size: imageSize)).size
        guard recipe.borderEnabled else { return size }
        let pad = min(max(recipe.borderWidth, 0), 0.3) * min(size.width, size.height)
        return CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
    }

    /// Renders only `region` (scaled picture pixels, origin top left) of the full-resolution picture
    /// at `region.scale`, with `recipe` applied. The crop and straighten are applied to the source
    /// lazily, the grade runs on that lazy picture (so every spatial effect follows the zoomed
    /// picture's size, as in the export), and Core Image renders just the region of interest.
    /// The frame carries its `placement` so the view can position it, and move it while a newer
    /// frame is being made.
    public func renderZoomed(_ recipe: Recipe, region: ZoomRegion) -> PreviewFrame? {
        Perf.interval("preview render zoomed") {
            guard region.scale > 0, let base = zoomBase(crop: recipe.crop, scale: region.scale) else { return nil }
            let graded = renderer.grade(recipe, cropped: base)
            let extent = graded.extent
            guard !extent.isInfinite, !extent.isEmpty else { return nil }
            let whole = CGRect(x: 0, y: 0, width: extent.width, height: extent.height)
            let r = region.rect.intersection(whole)
            guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
            // Core Image's origin is bottom left; the region's is top left.
            let ci = CGRect(x: extent.minX + r.minX, y: extent.maxY - r.maxY, width: r.width, height: r.height)
            return renderFrame(graded, from: ci,
                               placement: ZoomPlacement(scale: region.scale, origin: r.origin))
        }
    }

    /// The cropped picture at `scale` as a lazy image with origin zero. Cached per (source, crop, scale)
    /// so panning and slider changes reuse it. Below 100% it starts from the pyramid level that is
    /// still at least as sharp as asked for; above 100% it enlarges the full-resolution crop.
    func zoomBase(crop: CropSettings, scale: Double) -> CIImage? {
        guard let (source, generation) = snapshot() else { return nil }
        let key = ZoomBaseKey(generation: generation, crop: crop, scale: Int((scale * 1000).rounded()))
        lock.lock()
        if let hit = zoomBases[key] {
            zoomBaseOrder.removeAll { $0 == key }
            zoomBaseOrder.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        var level = 0
        while level < Self.maxLevel, scale < 1, 1 / Double(1 << (level + 1)) >= scale * 0.999 { level += 1 }
        guard let input = self.level(level, source: source, generation: generation) else { return nil }
        var image = CropGeometry.apply(crop, to: input)
        let e = image.extent
        if e.origin != .zero { image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)) }
        let factor = scale * Double(1 << level)
        if abs(factor - 1) > 1e-6 {
            let size = CGSize(width: max(1, (e.width * CGFloat(factor)).rounded()),
                              height: max(1, (e.height * CGFloat(factor)).rounded()))
            image = factor < 1
                ? Self.resample(image, to: size)
                : image.transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height))
                    .cropped(to: CGRect(origin: .zero, size: size))
        }
        lock.lock()
        if self.generation == generation {
            zoomBases[key] = image
            zoomBaseOrder.removeAll { $0 == key }
            zoomBaseOrder.append(key)
            while zoomBaseOrder.count > Self.zoomBaseLimit { zoomBases[zoomBaseOrder.removeFirst()] = nil }
        }
        lock.unlock()
        return image
    }

    // MARK: Thumbnail source

    /// The cropped picture fitted into `longSide` x `longSide`, as a small bitmap, for the film strip.
    public func thumbnailBase(crop: CropSettings, longSide: CGFloat) -> CIImage? {
        previewBase(crop: crop, canvas: CGSize(width: longSide, height: longSide))
    }

    /// Renders one thumbnail per id (nil is the untouched picture) from a single small base, up to
    /// `workers` at a time, calling `deliver` from the worker threads as each one lands. Blocks until
    /// done or `isCancelled` returns true.
    public func renderThumbnails(
        ids: [String?], crop: CropSettings, longSide: CGFloat, workers: Int = PreviewEngine.defaultThumbnailWorkers,
        isCancelled: @Sendable () -> Bool = { false },
        deliver: @Sendable (String?, CGImage) -> Void
    ) {
        let signpost = Perf.begin("thumbnail batch")
        defer { Perf.end("thumbnail batch", signpost) }
        guard let base = thumbnailBase(crop: crop, longSide: longSide), !ids.isEmpty else { return }
        let renderer = renderer, context = context
        let box = UncheckedBox(base)
        let next = NSLock()
        nonisolated(unsafe) var cursor = 0
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, ids.count))) { _ in
            while true {
                next.lock()
                let i = cursor; cursor += 1
                next.unlock()
                if i >= ids.count || isCancelled() { return }
                // The base already carries the crop, so the thumbnail recipe has none.
                if let cg = renderer.render(Recipe(filmID: ids[i]), input: box.value, context: context) {
                    deliver(ids[i], cg)
                }
            }
        }
    }

    // MARK: Buffers

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = PoolKey(width: width, height: height, format: format)
        lock.lock()
        var pool = pools[key]
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            if let created {
                pools[key] = created
                poolOrder.append(key)
                while poolOrder.count > 5 { pools[poolOrder.removeFirst()] = nil }
            }
        }
        lock.unlock()
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Tags the buffer and its IOSurface so Core Animation colour-matches the pixels from `space`.
    static func tag(_ buffer: CVPixelBuffer, _ space: CGColorSpace) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
           let plist = space.copyPropertyList() {
            IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, plist)
        }
    }
}

/// Carries a value across a closure boundary where the caller guarantees safe use.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
