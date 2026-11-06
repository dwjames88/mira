import CoreGraphics
import CoreImage
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

/// The app's real render shapes, run at the same time on the one shared `CIContext`: preview frames,
/// zoomed frames, thumbnails (which fan out with `concurrentPerform`), `PreviewProxy.make`, RAW develop plus the
/// bitmap proxy, histograms, the latitude meter, and export. `swift test` (parallel) of this package used to hang
/// with threads blocked in `-[CIContext lock]`; this test reproduces that shape and reports a hang as a failure
/// (after `timeout` seconds) instead of hanging the run.
@Suite("CIContext stress", .serialized) struct ContextStressTests {
    static let timeout: TimeInterval = 90
    /// For the RAW renders in this file; never the shared context (see `exhaustedCooperativePoolDoesNotStallARawRender`).
    static let rawContext = Renderer.makeContext()

    /// 1800x1200 sRGB bitmap with detail, as the loaders produce (CGImage backed).
    static func photo() -> CIImage {
        let w = 1800, h = 1200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<60 {
            let v = CGFloat(i) / 60
            ctx.setFillColor(CGColor(colorSpace: space, components: [v, 1 - v, 0.5 + 0.4 * sin(v * 9), 1])!)
            ctx.fill(CGRect(x: i * 30, y: 0, width: 30, height: h))
        }
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        for x in stride(from: 100, to: 1700, by: 6) { ctx.fill(CGRect(x: x, y: 300, width: 2, height: 600)) }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Runs `body` on `count` plain threads (not the Swift cooperative pool) and returns whether they all
    /// finished within `timeout`.
    static func runAll(count: Int, timeout: TimeInterval, _ body: @escaping @Sendable (Int) -> Void) -> Bool {
        let group = DispatchGroup()
        for i in 0..<count {
            group.enter()
            let thread = Thread { body(i); group.leave() }
            thread.stackSize = 8 << 20
            thread.start()
        }
        return group.wait(timeout: .now() + timeout) == .success
    }

    @Test func sharedContextSurvivesConcurrentRenderShapes() throws {
        let library = try SyntheticFilms.library([
            .init(id: "neg", family: .colorNegative, cube: .square),
            .init(id: "slide", family: .slide, cube: .invert),
            .init(id: "bw", family: .blackAndWhite, monochrome: true),
        ])
        let renderer = Renderer(library: library)
        let context = Renderer.sharedContext
        let photo = Self.photo()
        let engine = PreviewEngine(renderer: renderer, context: context)
        engine.setSource(photo)

        var rich = Recipe(filmID: "neg", exposure: 0.3, contrast: 0.2, saturation: 0.1, warmth: 0.2, tint: 0.1,
                          grainAmount: 0.5, halationAmount: 0.5, bloomAmount: 0.4, vignetteAmount: 0.3)
        rich.highlights = -0.2; rich.shadows = 0.2; rich.clarity = 0.2; rich.texture = 0.2
        rich.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        let recipe = rich

        let rawURL = RawSamples.iphoneXS
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mira-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let rounds = Int(ProcessInfo.processInfo.environment["MIRA_STRESS_ROUNDS"] ?? "") ?? 12

        let finished = Self.runAll(count: 10, timeout: Self.timeout) { worker in
            for round in 0..<rounds {
                switch (worker + round) % 12 {
                case 0:
                    // Preview frames at several canvas sizes (new bases each time).
                    let side = CGFloat(300 + 64 * ((worker * 7 + round) % 8))
                    var r = recipe; r.exposure = Double(round) / 20
                    _ = engine.render(r, canvas: CGSize(width: side, height: side))
                case 1:
                    // Thumbnails: a concurrentPerform fan-out on the same context.
                    engine.renderThumbnails(ids: [nil, "neg", "slide", "bw"], crop: .identity, longSide: 160, workers: 4) { _, _ in }
                case 2:
                    var crop = CropSettings.identity
                    crop.straighten = Double(round % 5)
                    _ = engine.thumbnailSourceHash(crop: crop, longSide: 120)
                case 3:
                    // The iOS preview proxy: createCGImage then wrap.
                    var tag = photo
                    tag = tag.withMiraHeadroom(1)
                    _ = PreviewProxy.make(from: tag, renderer: renderer, context: context, wanted: 700)
                case 4:
                    // Histogram of a frame, and a CGImage copy of it.
                    if let frame = engine.render(recipe, canvas: CGSize(width: 512, height: 512)) {
                        _ = HistogramData.compute(frame: frame)
                        _ = frame.cgImage(context: context)
                    }
                case 5:
                    if let base = engine.previewBase(crop: .identity, canvas: CGSize(width: 640, height: 640)) {
                        _ = renderer.latitudeReading(recipe, input: base, context: context)
                    }
                case 6:
                    let url = out.appendingPathComponent("e-\(worker)-\(round).jpg")
                    try? renderer.export(recipe, source: photo, metadataFrom: nil, outputURL: url, type: .jpeg, quality: 0.8)
                case 7:
                    // Zoomed frame (lazy full-resolution crop and region render).
                    let region = ZoomRegion(scale: 1, rect: CGRect(x: 100, y: 100, width: 600, height: 400))
                    _ = engine.renderZoomed(recipe, region: region)
                case 8:
                    // RAW develop, its bitmap proxy, and a graded render of it.
                    if let rawURL, let develop = RawDevelop(url: rawURL),
                       let developed = develop.develop(.identity, filmApplied: true, draft: true, scale: 0.25) {
                        let proxy = RawOpener.bitmapProxy(of: developed) ?? developed
                        _ = renderer.render(recipe, input: proxy.image, context: context)
                    }
                case 9:
                    // A lazy RAW decode rendered straight on a context of its own. (On the shared context it stalls the
                    // whole process when many threads wait on that context: see the second test.)
                    if let rawURL, let develop = RawDevelop(url: rawURL),
                       let image = develop.apply(.identity, filmApplied: false, draft: true, scale: 0.25) {
                        _ = renderer.render(recipe, input: image, context: Self.rawContext)
                    }
                case 10:
                    // A preview engine whose source is a lazy RAW decode: its pyramid is materialised on the shared context.
                    if let rawURL, let develop = RawDevelop(url: rawURL),
                       let developed = develop.develop(.identity, filmApplied: true, draft: true, scale: 0.25) {
                        let raw = PreviewEngine(renderer: renderer, context: context)
                        raw.setSource(developed.image)
                        _ = raw.render(recipe, canvas: CGSize(width: 400, height: 400))
                    }
                default:
                    // Many different films' thumbnails through the one-shot render path.
                    _ = renderer.render(Recipe(filmID: "slide", grainAmount: 0.3), input: photo, context: context)
                }
            }
        }
        #expect(finished, "render shapes did not finish within \(Self.timeout) s: deadlock on the shared CIContext")
    }

    /// The shape of `swift test` (parallel): synchronous tests run on Swift concurrency's cooperative pool, one
    /// thread per core. A lazily decoded RAW (`CIRAWFilter`) is decoded by RawCamera INSIDE the render, on libdispatch
    /// workers, while the rendering context stays locked. When that context is the one every other test renders on, the
    /// pool threads all park on its lock, the decode's workers are never scheduled, and nothing ever finishes
    /// (threads blocked in `-[CIContext lock]` under `CI::Context::recursive_render`; RawCamera-Provider-Render-Queue
    /// in `dispatch_group_wait`). Measured on a 10-core machine with the RAW on the shared context: 3 and 5 tasks
    /// finish, 9 and 14 never do. So RAW is rendered on a context of its own (`private`) or through a
    /// `PreviewEngine`, whose `decodeContext` is not the interactive one (`engine`); both finish with
    /// more tasks than cores.
    @Test(arguments: ["private", "engine"]) func rawRenderDoesNotStallWhileThePoolIsParkedOnTheSharedContext(mode: String) throws {
        let rawURL = try #require(RawSamples.iphoneXS)
        let library = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative, cube: .square)])
        let renderer = Renderer(library: library)
        let context = Renderer.sharedContext
        let photo = Self.photo()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let width = cores + 4
        let rawContext = Renderer.makeContext()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<width {
                    group.addTask {
                        for _ in 0..<6 {
                            if i == 0 {
                                guard let develop = RawDevelop(url: rawURL),
                                      let image = develop.apply(.identity, filmApplied: false, draft: true, scale: 0.25) else { continue }
                                if mode == "engine" {
                                    let engine = PreviewEngine(renderer: renderer, context: context)
                                    engine.setSource(image)
                                    _ = engine.render(Recipe(filmID: "neg"), canvas: CGSize(width: 500, height: 400))
                                } else {
                                    _ = renderer.render(Recipe(filmID: "neg"), input: image, context: rawContext)
                                }
                            } else {
                                _ = renderer.render(Recipe(filmID: "neg", grainAmount: 0.4), input: photo, context: context)
                            }
                        }
                    }
                }
            }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 60) == .success
        #expect(finished, "\(width) tasks on \(cores) cores, RAW via \(mode): the render never finished (pool threads parked on the shared context)")
    }
}
