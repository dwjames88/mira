import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing
@testable import MiraCore

/// Roll 1 render-budget proxy for the camera finder, measured on whatever Mac runs it. Skipped unless
/// `MIRA_PERF=1` (it prints a table, it does not assert speed). Frames are rendered the way the finder will: a
/// Metal-queue `CIContext` with the shared working space and format, `startTask(toRender:to:)` into a bgra8 texture,
/// waited on, a new `CIImage` over a pixel buffer each frame with one pixel changed, and a new grain seed each frame.
///
///     MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --package-path Packages/MiraCore --filter FinderBudgetBenchmark
@Suite("Finder budget benchmark", .serialized)
struct FinderBudgetBenchmark {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MIRA_PERF"] == "1" }

    static let warmup = 20
    static let frames = 90

    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    static func stats(_ samples: [Double]) -> (median: Double, p95: Double) {
        let s = samples.sorted()
        guard !s.isEmpty else { return (0, 0) }
        return (s[s.count / 2], s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)])
    }

    /// A BGRA pixel buffer of `size` filled with the fixture (cover-fitted), or a synthetic scene when it is missing.
    static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        let pb = buffer!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let url = repoRoot().appendingPathComponent("Fixtures/sample.jpg")
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let s = max(CGFloat(width) / CGFloat(img.width), CGFloat(height) / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        } else {
            for x in 0..<width {
                let v = CGFloat(x) / CGFloat(width)
                ctx.setFillColor(CGColor(colorSpace: space, components: [v, 0.5, 1 - v, 1])!)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
            ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            ctx.fill(CGRect(x: width / 3, y: height / 3, width: width / 8, height: height / 8))
        }
        return pb
    }

    /// A new `CIImage` over the buffer with one pixel changed (so no render is a cache hit).
    static func frameImage(_ pb: CVPixelBuffer, index: Int) -> CIImage {
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            base.assumingMemoryBound(to: UInt8.self)[index % 200] = UInt8(truncatingIfNeeded: index)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return CIImage(cvPixelBuffer: pb, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }

    static func realFilmLibrary() -> (FilmLibrary, String)? {
        let dir = repoRoot().appendingPathComponent("Films")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("films.json").path),
              let lib = try? FilmLibrary(directory: dir) else { return nil }
        for id in ["kodak-portra-400", "kodak-portra-160", "kodak-gold-200"] where lib.film(id: id) != nil && (try? lib.lut(for: lib.film(id: id)!)) != nil {
            return (lib, id)
        }
        for f in lib.films where (try? lib.lut(for: f)) != nil { return (lib, f.id) }
        return nil
    }

    struct Case {
        var name: String
        var grain = true
        var textureScale: CGFloat = 1
        var renderScale: CGFloat = 1
    }

    /// Median and p95 ms per frame for one case at one frame size.
    static func measure(_ c: Case, renderer base: Renderer, recipe: Recipe, pb: CVPixelBuffer, size: (Int, Int),
                        context: CIContext, queue: MTLCommandQueue) -> (median: Double, p95: Double) {
        var recipe = recipe
        if !c.grain { recipe.grainAmount = 0 }
        let w = max(1, Int((CGFloat(size.0) * c.renderScale).rounded())), h = max(1, Int((CGFloat(size.1) * c.renderScale).rounded()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        guard let texture = queue.device.makeTexture(descriptor: desc) else { return (0, 0) }
        var samples: [Double] = []
        for i in 0..<(warmup + frames) {
            var image = frameImage(pb, index: i)
            if c.renderScale < 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(size.0), y: CGFloat(h) / CGFloat(size.1)))
            }
            let renderer = base.withGrainSeed(Double(i * 7919 + 1)).withTextureScale(c.textureScale)
                .withPreviewScale(c.renderScale)
            let t0 = now()
            let out = renderer.apply(recipe, to: image)
            guard let cb = queue.makeCommandBuffer() else { continue }
            let dest = CIRenderDestination(mtlTexture: texture, commandBuffer: cb)
            dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            dest.isFlipped = true
            do {
                let task = try context.startTask(toRender: out, to: dest)
                cb.commit()
                _ = try task.waitUntilCompleted()
                cb.waitUntilCompleted()
            } catch { continue }
            if i >= warmup { samples.append(now() - t0) }
        }
        return stats(samples)
    }

    @Test(.enabled(if: FinderBudgetBenchmark.enabled)) func finderBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("SKIPPED: no Metal device"); return
        }
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
            .name: "MiraFinderBench",
        ]
        let context = CIContext(mtlCommandQueue: queue, options: options)
        let real = Self.realFilmLibrary()
        let library = try real?.0 ?? SyntheticFilms.library([.init(id: "synthetic", family: .colorNegative)])
        let filmID = real?.1 ?? "synthetic"
        let renderer = Renderer(library: library)
        let recipe = Recipe(filmID: filmID).applyingNativeTexture(filmID: filmID)

        var lines: [String] = []
        lines.append("Film: \(filmID)\(real == nil ? " (synthetic, films not present)" : ""); native grain, halation and bloom at 50 %; "
                     + "\(Self.frames) frames after \(Self.warmup) warm-up; ms per frame (CPU encode to GPU complete).")
        lines.append("")
        lines.append("| Case | 1920x1440 median | 1920x1440 p95 | 1206x1809 median | 1206x1809 p95 |")
        lines.append("|---|---|---|---|---|")
        let cases = [Case(name: "full"), Case(name: "grain off", grain: false),
                     Case(name: "textureScale 0.5", textureScale: 0.5),
                     Case(name: "textureScale 0.5 + grain off", grain: false, textureScale: 0.5),
                     Case(name: "renderScale 0.75", renderScale: 0.75)]
        let sizes = [(1920, 1440), (1206, 1809)]
        let buffers = sizes.map { Self.makeBuffer(width: $0.0, height: $0.1) }
        // Prewarm the film's LUT and the kernels on both sizes.
        for c in cases {
            var row = "| \(c.name) |"
            for (i, size) in sizes.enumerated() {
                let m = Self.measure(c, renderer: renderer, recipe: recipe, pb: buffers[i], size: size, context: context, queue: queue)
                row += String(format: " %.1f | %.1f |", m.median, m.p95)
            }
            lines.append(row)
        }

        // Latitude reading on a 1920x1440 frame.
        var latitude: [Double] = []
        for i in 0..<(Self.warmup + Self.frames) {
            let image = Self.frameImage(buffers[0], index: i)
            let t0 = Self.now()
            _ = renderer.latitudeReading(recipe, input: image, context: context)
            if i >= Self.warmup { latitude.append(Self.now() - t0) }
        }
        let lat = Self.stats(latitude)

        // Eight film-strip thumbnails at 220 px (different films when there are enough, else the same one).
        let ids = real == nil ? Array(repeating: filmID, count: 8)
            : Array((library.films.filter { (try? library.lut(for: $0)) != nil }).prefix(8).map(\.id))
        var thumbs: [Double] = []
        for round in 0..<12 {
            let base = renderer.previewImage(from: Self.frameImage(buffers[0], index: round), maxPixelSize: 220)
            let t0 = Self.now()
            for id in ids {
                let r = Recipe(filmID: id).applyingNativeTexture(filmID: id)
                let out = renderer.thumbnail(r, input: base)
                _ = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            if round >= 2 { thumbs.append(Self.now() - t0) }
        }
        let th = Self.stats(thumbs)
        lines.append("")
        lines.append(String(format: "latitudeReading on 1920x1440: median %.2f ms, p95 %.2f ms (%d runs)", lat.median, lat.p95, Self.frames))
        lines.append(String(format: "8 thumbnail renders at 220 px: median %.1f ms, p95 %.1f ms for the batch (%d films, 10 runs)", th.median, th.p95, ids.count))
        let text = lines.joined(separator: "\n")
        print("\n=== FinderBudgetBenchmark ===\n" + text + "\n=== end ===")
        #expect(!text.isEmpty)
    }
}
