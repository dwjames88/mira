#if os(iOS)
import CoreImage
import Foundation
import Metal
import MiraCameraKit
import MiraCore
import QuartzCore
import Synchronization
import os

/// Finder state set from the main actor (CameraModel) and read on the finder queue.
public struct FinderState: Sendable {
    /// The user's recipe (film, push, exposure ...). The finder derives its own copy from it; it is never changed here.
    public var recipe = Recipe()
    /// `.auto` lets the fallback ladder decide; the others pin a level (developer / settings override).
    public var mode: FinderQualityMode = .auto
    /// The user's FINDER: LIVE / OFF setting.
    public var grainLive = true
    /// Bare scene: no film, no grade, only rotation and fit.
    public var showingOriginal = false
    /// Long side in pixels of the photo the capture will save (for the grain and halation scale).
    public var captureLongSide: Double = 4032
    /// Digital zoom crop, normalized (0...1) in the upright frame with the origin at the TOP LEFT. nil = whole frame.
    public var cropRect: CGRect?
    public var thermal: FinderThermalLevel = .nominal
    /// Film IDs the film door wants thumbnails of. Empty = the door is closed and no thumbnails are made.
    public var cardFilmIDs: [String] = []

    public init() {}
}

/// Measurements published about once a second.
public struct FinderStats: Sendable, Equatable {
    public var medianMS: Double
    public var p95MS: Double
    public var fps: Double
    /// Frames dropped because the previous one had not finished (latest wins), since the renderer was created.
    public var drops: Int
    public var level: FinderLevel
    public var quality: FinderQuality
    /// Duration of the last latitude reading, nil until one has run.
    public var latitudeMS: Double?
}

/// Renders camera frames through the film graph into a `CAMetalLayer`, latest frame wins.
///
/// `@unchecked Sendable`: the class has no mutable stored properties outside `core`, a `Mutex` that is the only
/// shared mutable state (the state set from the main actor, the ladder, counters, the in-flight flag, the layer).
/// Everything else is `let` and thread safe (`MTLDevice`, `MTLCommandQueue`, `CIContext`, `Renderer`). Frames arrive
/// on the capture frame queue, Metal completion handlers run on a Metal thread and touch only `core`; the utility
/// queues touch `core` and the immutable members. Callbacks are `@Sendable`; the receiver hops to the main actor.
public final class FinderRenderer: @unchecked Sendable {
    public static let subsystem = "com.fieldframes.mira"

    private struct LayerBox: @unchecked Sendable { let layer: CAMetalLayer }
    private struct TextureBox: @unchecked Sendable { let texture: MTLTexture }

    private struct Core {
        var state = FinderState()
        var ladder = FallbackLadder()
        var layer: LayerBox?
        var offscreen: TextureBox?
        var drawableSize = CGSize(width: 1, height: 1)
        var inflight = false
        var nextDue = -Double.infinity
        var accepted = 0
        var drops = 0
        var presentedInWindow = 0
        var gpuSamples: [Double] = []
        var windowStart: Double?
        var lastImage: CIImage?
        var meterBusy = false
        var cardsBusy = false
        var lastCardTime = -Double.infinity
        var lastMeterTime = -Double.infinity
        /// The latest upright frame (cards start from it the moment the door opens, without waiting for a frame).
        var lastUpright: CIImage?
        /// Rendered cards for the scene whose coarse signature is `cardSignature`; `cardPublished` are the ids the UI has.
        var cardCache: [String: CGImage] = [:]
        var cardSignature: [UInt8]?
        var cardPublished: Set<String> = []
        var latitudeMS: Double?
        var onStats: (@Sendable (FinderStats) -> Void)?
        var onLatitude: (@Sendable (LatitudeReading?) -> Void)?
        var onCards: (@Sendable ([String: CGImage]) -> Void)?
    }

    private let core = Mutex(Core())
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let renderer: Renderer?
    private let signposter = OSSignposter(subsystem: FinderRenderer.subsystem, category: "camera")
    private let work = DispatchQueue(label: "com.fieldframes.mira.finder.work", qos: .utility)
    private let ink = CIImage(color: CIColor(red: 0.082, green: 0.078, blue: 0.059, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)

    /// The latitude meter reads the frame at most this often (seconds): 4 Hz, from a copy of at most `meterLongSide` pixels.
    static let meterInterval = 0.25
    static let meterLongSide: CGFloat = 256
    /// Film door cards are refreshed at most this often (seconds), from one copy of the frame at this long side (pixels).
    static let cardInterval = 0.5
    static let cardLongSide: CGFloat = 240
    /// A scene counts as changed when a cell of its 8x8 average moves by more than this (of 255).
    static let cardSceneTolerance = 10
    static let cardWorkers = 3
    static let cardCacheLimit = 80

    /// nil without a Metal device. `renderer` is injectable for tests; by default the app bundle's films
    /// (without them the finder shows the bare scene).
    public init?(renderer: Renderer? = nil) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.renderer = renderer ?? FilmLibrary.bundled(in: .main).map { Renderer(library: $0) }
        // The same working space and format as `Renderer.makeContext`, on our own queue.
        self.ciContext = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .name: "MiraFinder",
        ])
    }

    public var metalDevice: MTLDevice { device }

    // MARK: Setup

    /// Configures `layer` and makes it the render target. Call on the main actor; the layer's size is set by the view.
    @MainActor public func attach(to layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        let size = layer.drawableSize
        // The layer stays on its view; the finder queue only calls `nextDrawable()`, which is thread safe.
        let box = LayerBox(layer: layer)
        store(box, size: size)
    }

    /// Nonisolated so the lock's closure does not inherit the main actor.
    private nonisolated func store(_ box: LayerBox, size: CGSize) {
        core.withLock {
            $0.layer = box
            $0.offscreen = nil
            if size.width >= 1, size.height >= 1 { $0.drawableSize = size }
        }
    }

    /// The view's drawable size in pixels (bounds x screen scale). The view also sets `layer.drawableSize` on the main thread.
    public func setDrawableSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        core.withLock { $0.drawableSize = size }
    }

    /// Renders into an offscreen texture instead of a layer (benchmark and tests).
    func attachOffscreen(width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead, .renderTarget]
        let texture = device.makeTexture(descriptor: d).map(TextureBox.init)
        core.withLock {
            $0.layer = nil
            $0.offscreen = texture
            $0.drawableSize = CGSize(width: width, height: height)
        }
    }

    // MARK: State

    /// Mutates the finder state under the lock. Safe from any thread; the body must be quick.
    public func update(_ body: (inout FinderState) -> Void) {
        let cardsChanged: Bool = core.withLock { c in
            let oldCards = c.state.cardFilmIDs
            body(&c.state)
            c.ladder.mode = c.state.mode
            c.ladder.grainLiveSetting = c.state.grainLive
            c.ladder.thermal = c.state.thermal
            // A closed door has nothing on screen: the next opening gets every card again (from the cache when the scene is the same).
            if c.state.cardFilmIDs.isEmpty { c.cardPublished = [] }
            else if oldCards.isEmpty { c.cardPublished = [] }
            return c.state.cardFilmIDs != oldCards && !c.state.cardFilmIDs.isEmpty
        }
        // The door asked for cards: start now from the latest frame, no waiting for the next frame or the 2 Hz gate.
        if cardsChanged { startCards() }
    }

    public func setThermal(_ level: FinderThermalLevel) { update { $0.thermal = level } }

    public static func thermalLevel(_ state: ProcessInfo.ThermalState) -> FinderThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }

    /// The quality in force (override, or the ladder's level raised to the thermal floor).
    public var quality: FinderQuality { core.withLock { $0.ladder.quality } }

    public func setStatsHandler(_ handler: (@Sendable (FinderStats) -> Void)?) { core.withLock { $0.onStats = handler } }
    public func setLatitudeHandler(_ handler: (@Sendable (LatitudeReading?) -> Void)?) { core.withLock { $0.onLatitude = handler } }
    public func setCardsHandler(_ handler: (@Sendable ([String: CGImage]) -> Void)?) { core.withLock { $0.onCards = handler } }

    /// The last presented frame (film applied, over ink) as an 8-bit sRGB image, nil before the first frame.
    /// Renders on the calling thread; call from a background task. Holds the last frame's pixel buffer until the
    /// next frame replaces it, `releaseSnapshotSource()` lets go earlier.
    public func snapshot() -> CGImage? {
        guard let image = core.withLock({ $0.lastImage }) else { return nil }
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    public func releaseSnapshotSource() { core.withLock { $0.lastImage = nil; $0.lastUpright = nil } }

    // MARK: Frames

    /// Called on the frame queue for every camera frame.
    public func consume(_ frame: FinderFrame) {
        _ = consume(frame, completion: nil)
    }

    /// `completion` gets the wall milliseconds from the start of this call to GPU completion.
    /// Returns false when the frame was skipped (frame-rate cap, a frame still in flight, or no target).
    @discardableResult
    func consume(_ frame: FinderFrame, completion: (@Sendable (Double) -> Void)?) -> Bool {
        let t0 = DispatchTime.now().uptimeNanoseconds

        struct Plan {
            var state: FinderState
            var quality: FinderQuality
            var layer: LayerBox?
            var offscreen: TextureBox?
            var size: CGSize
            var meter: Bool
            var cards: Bool
        }
        let plan: Plan? = core.withLock { c in
            let q = c.ladder.quality
            let period = 1 / Double(max(1, q.frameRate))
            guard frame.timestamp >= c.nextDue - 0.004 else { return nil }
            guard !c.inflight else { c.drops += 1; return nil }
            c.inflight = true
            c.nextDue = c.nextDue + period < frame.timestamp - period ? frame.timestamp + period : c.nextDue + period
            c.accepted += 1
            var cards = false
            if !c.state.cardFilmIDs.isEmpty, !c.cardsBusy, frame.timestamp - c.lastCardTime >= Self.cardInterval {
                c.lastCardTime = frame.timestamp
                cards = true
            }
            var meter = false
            if !c.meterBusy, frame.timestamp - c.lastMeterTime >= Self.meterInterval {
                c.lastMeterTime = frame.timestamp
                meter = true
            }
            return Plan(state: c.state, quality: q, layer: c.layer, offscreen: c.offscreen, size: c.drawableSize,
                        meter: meter, cards: cards)
        }
        guard let plan else { return false }
        func release() { core.withLock { $0.inflight = false } }

        let upright = Self.upright(frame, crop: plan.state.cropRect)
        let extent = upright.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { release(); return false }

        // Target texture.
        let state = signposter.beginInterval("finder frame", id: signposter.makeSignpostID())
        var drawable: CAMetalDrawable?
        let texture: MTLTexture
        if let off = plan.offscreen {
            texture = off.texture
        } else if let layer = plan.layer?.layer, let d = layer.nextDrawable() {
            drawable = d
            texture = d.texture
        } else {
            signposter.endInterval("finder frame", state)
            release()
            return false
        }
        let target = CGSize(width: texture.width, height: texture.height)

        // Fit the upright frame into the target at the quality's render scale; the graph runs at that size.
        let rs = CGFloat(plan.quality.renderScale)
        let box = CGSize(width: target.width * rs, height: target.height * rs)
        let s = min(box.width / extent.width, box.height / extent.height)
        let gradedSize = CGSize(width: extent.width * s, height: extent.height * s)
        var scaled = upright
        if abs(s - 1) > 1e-4 { scaled = upright.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
        scaled = scaled.withMiraHeadroom(1).withMiraExposureTime(frame.exposureTime)

        var picture = scaled
        if !plan.state.showingOriginal, let renderer {
            let previewScale = FinderRecipe.previewScale(finderLongSide: Double(max(gradedSize.width, gradedSize.height)),
                                                         captureLongSide: plan.state.captureLongSide)
            let seed = plan.quality.grainLive ? FinderRecipe.grainSeed(frameIndex: frame.index) : nil
            picture = renderer.withPreviewScale(CGFloat(previewScale))
                .withGrainSeed(seed)
                .withTextureScale(CGFloat(plan.quality.textureScale))
                .apply(FinderRecipe.recipe(from: plan.state.recipe, quality: plan.quality), to: scaled)
        }
        let pe = picture.extent
        guard pe.width >= 1, pe.height >= 1, pe.width.isFinite, pe.height.isFinite else {
            signposter.endInterval("finder frame", state)
            release()
            return false
        }
        // Upscale (render scale below 1), center, over ink.
        let up = 1 / rs
        let placedW = pe.width * up, placedH = pe.height * up
        let tx = ((target.width - placedW) / 2).rounded(.down), ty = ((target.height - placedH) / 2).rounded(.down)
        let placed = picture
            .transformed(by: CGAffineTransform(translationX: -pe.minX, y: -pe.minY))
            .transformed(by: CGAffineTransform(scaleX: up, y: up).concatenating(CGAffineTransform(translationX: tx, y: ty)))
        let bounds = CGRect(origin: .zero, size: target)
        let canvas = placed.composited(over: ink).cropped(to: bounds)

        guard let cb = queue.makeCommandBuffer() else {
            signposter.endInterval("finder frame", state)
            release()
            return false
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: cb)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        destination.isFlipped = true

        let timestamp = frame.timestamp
        cb.addCompletedHandler { [self, signposter] buffer in
            signposter.endInterval("finder frame", state)
            let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            self.finish(buffer, timestamp: timestamp, wallMS: wall)
            completion?(wall)
        }
        do {
            _ = try ciContext.startTask(toRender: canvas, to: destination)
        } catch {
            signposter.endInterval("finder frame", state)
            release()
            return false
        }
        if let drawable { cb.present(drawable) }
        core.withLock { $0.lastImage = canvas; $0.lastUpright = upright }
        cb.commit()

        if plan.meter, let renderer { startMeter(renderer, recipe: plan.state.recipe, image: upright) }
        if plan.cards { startCards() }
        return true
    }

    /// The frame rotated upright (a multiple of 90 degrees by orientation, else a rotation) and cropped, origin at zero.
    public static func upright(_ frame: FinderFrame, crop: CGRect?) -> CIImage {
        var angle = frame.rotationAngle.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        var image = frame.image
        let quarter = (angle / 90).rounded()
        if abs(angle - quarter * 90) < 0.5 {
            let orientation: CGImagePropertyOrientation = switch Int(quarter) % 4 {
            case 1: .right
            case 2: .down
            case 3: .left
            default: .up
            }
            if orientation != .up { image = image.oriented(orientation) }
        } else {
            // Clockwise `angle` in Core Image's y-up space is a rotation by -angle.
            image = image.transformed(by: CGAffineTransform(rotationAngle: -angle * .pi / 180))
        }
        var e = image.extent
        if let crop, crop.width > 0, crop.height > 0 {
            let r = CGRect(x: e.minX + crop.minX * e.width, y: e.minY + (1 - crop.maxY) * e.height,
                           width: crop.width * e.width, height: crop.height * e.height).intersection(e)
            if !r.isNull, r.width >= 1, r.height >= 1 { image = image.cropped(to: r); e = r }
        }
        if e.minX != 0 || e.minY != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        }
        return image
    }

    /// Metal completion (a Metal thread): releases the in-flight flag, feeds the ladder, publishes stats about once a second.
    private func finish(_ buffer: MTLCommandBuffer, timestamp: Double, wallMS: Double) {
        let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        let ms = gpu > 0 ? gpu : wallMS
        let ok = buffer.status == .completed
        let publish: (@Sendable (FinderStats) -> Void, FinderStats)? = core.withLock { c in
            c.inflight = false
            guard ok else { return nil }
            c.presentedInWindow += 1
            c.gpuSamples.append(ms)
            c.ladder.record(frameMilliseconds: ms, at: timestamp)
            let start = c.windowStart ?? timestamp
            c.windowStart = start
            guard timestamp - start >= 1, let handler = c.onStats else { return nil }
            let sorted = c.gpuSamples.sorted()
            let stats = FinderStats(
                medianMS: sorted[sorted.count / 2],
                p95MS: sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)],
                fps: Double(c.presentedInWindow) / (timestamp - start),
                drops: c.drops, level: c.ladder.level, quality: c.ladder.quality, latitudeMS: c.latitudeMS)
            c.gpuSamples.removeAll(keepingCapacity: true)
            c.presentedInWindow = 0
            c.windowStart = timestamp
            return (handler, stats)
        }
        if let (handler, stats) = publish { handler(stats) }
    }

    // MARK: Meter and cards

    /// `image` scaled (affine, no resampling filter beyond the default bilinear) so its long side is at most
    /// `longSide`, with an integral extent at the origin. Lazy: nothing renders until it is used.
    static func shrunk(_ image: CIImage, longSide: CGFloat) -> CIImage {
        let e = image.extent
        let long = max(e.width, e.height)
        guard long > longSide, e.width >= 1, e.height >= 1, !e.isInfinite else { return image }
        let k = longSide / long
        let w = max(1, (e.width * k).rounded()), h = max(1, (e.height * k).rounded())
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: w / e.width, y: h / e.height))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func startMeter(_ renderer: Renderer, recipe: Recipe, image: CIImage) {
        let go = core.withLock { c in
            if c.meterBusy { return false }
            c.meterBusy = true
            return true
        }
        guard go else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            // At most 256 px, so `latitudeReading` does not run its own full-frame Lanczos.
            let small = Self.shrunk(image, longSide: Self.meterLongSide)
            let reading = renderer.latitudeReading(recipe, input: small, context: ciContext)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let handler = core.withLock { c in
                c.meterBusy = false
                c.latitudeMS = ms
                return c.onLatitude
            }
            handler?(reading)
        }
    }

    /// Starts a card batch from the latest upright frame unless one is already running (a running batch re-reads the
    /// wanted ids when it finishes a pass, so ids that arrive meanwhile are picked up).
    func startCards() {
        guard let renderer else { return }
        let image: CIImage? = core.withLock { c in
            guard !c.cardsBusy, !c.state.cardFilmIDs.isEmpty, let image = c.lastUpright else { return nil }
            c.cardsBusy = true
            return image
        }
        guard let image else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runCards(renderer, image: image)
            core.withLock { $0.cardsBusy = false }
        }
    }

    /// One 240 px copy of the frame, materialized once; the cards render from it through the film LUT stage only
    /// (no grain, halation or bloom), up to `cardWorkers` at a time, and each is published as soon as it is done.
    private func runCards(_ renderer: Renderer, image: CIImage) {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let shrunk = Self.shrunk(image, longSide: Self.cardLongSide)
        let rect = shrunk.extent
        guard rect.width >= 1, rect.height >= 1,
              let copy = ciContext.createCGImage(shrunk, from: rect, format: .RGBA8, colorSpace: sRGB) else { return }
        let small = CIImage(cgImage: copy).withMiraHeadroom(1)
        let signature = Self.signature(of: copy)
        let scale = min(1, max(rect.width, rect.height) / max(image.extent.width, image.extent.height))
        let r = renderer.withPreviewScale(scale)

        // A new scene drops the cached cards; a still scene keeps them (small drift is measured against the scene
        // the cards were made from, so it adds up to a change eventually).
        core.withLock { c in
            if let old = c.cardSignature, zip(old, signature).allSatisfy({ abs(Int($0) - Int($1)) <= Self.cardSceneTolerance }) { return }
            c.cardCache = [:]
            c.cardPublished = []
            c.cardSignature = signature
        }

        while true {
            let step: (ready: [String: CGImage], todo: [String], handler: (@Sendable ([String: CGImage]) -> Void)?) = core.withLock { c in
                var ready: [String: CGImage] = [:]
                var todo: [String] = []
                for id in c.state.cardFilmIDs where !c.cardPublished.contains(id) {
                    if let hit = c.cardCache[id] { ready[id] = hit; c.cardPublished.insert(id) } else { todo.append(id) }
                }
                return (ready, todo, c.onCards)
            }
            if !step.ready.isEmpty { step.handler?(step.ready) }
            if step.todo.isEmpty { if step.ready.isEmpty { return } else { continue } }

            let next = NSLock()
            nonisolated(unsafe) var cursor = 0
            // A few at a time, so cards that were requested (or moved up) meanwhile are not stuck behind a long pass.
            let todo = Array(step.todo.prefix(Self.cardWorkers * 2))
            DispatchQueue.concurrentPerform(iterations: min(Self.cardWorkers, todo.count)) { _ in
                while true {
                    next.lock()
                    let i = cursor; cursor += 1
                    next.unlock()
                    if i >= todo.count { return }
                    let id = todo[i]
                    // "__original" is the door's key for the no-look card.
                    let filmID: String? = id == "__original" ? nil : id
                    var recipe = Recipe(filmID: filmID, reciprocity: .off).applyingNativeTexture(filmID: filmID)
                    recipe.grainAmount = 0
                    recipe.halationAmount = 0
                    recipe.bloomAmount = 0
                    // The LUT for this card loads here, on demand (nothing waits for the other films).
                    let graded = r.thumbnail(recipe, input: small)
                    guard let cg = ciContext.createCGImage(graded, from: graded.extent, format: .RGBA8, colorSpace: sRGB) else { continue }
                    let handler: (@Sendable ([String: CGImage]) -> Void)? = core.withLock { c in
                        // Dropped if the scene moved on meanwhile or the door no longer wants it.
                        guard c.cardSignature == signature, c.state.cardFilmIDs.contains(id) else { return nil }
                        if c.cardCache.count >= Self.cardCacheLimit { c.cardCache = c.cardCache.filter { c.state.cardFilmIDs.contains($0.key) } }
                        c.cardCache[id] = cg
                        c.cardPublished.insert(id)
                        return c.onCards
                    }
                    handler?([id: cg])
                }
            }
            // Loop: ids requested while this pass ran are rendered next, in the same batch.
        }
    }

    /// 8x8 average of the copy, RGB (192 bytes): a cheap stand-in for a frame hash.
    static func signature(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return bytes
    }
}
#endif
