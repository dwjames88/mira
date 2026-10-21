import CoreGraphics
import CoreImage
import Foundation
import MiraCore

/// The optimised pipeline: canvas-resolution bases, IOSurface frames, decoded sources.
enum Current {
    static func run(renderer: Renderer, library: FilmLibrary, context: CIContext, jpeg: URL,
                    filmsURL: URL, benchDir: URL) throws {
        print("== current pipeline ==")
        let canvas = Bench.canvasPixels
        // b. open: thumbnail decode -> first frame; then the full decode
        let engine = PreviewEngine(renderer: renderer, context: context)
        let (thumb, thumbMs) = Bench.time { ImageSource.loadThumbnail(url: jpeg, maxPixelSize: max(canvas.width, canvas.height))! }
        engine.setSource(thumb)
        let (first, firstMs) = Bench.time { engine.render(Recipe(filmID: Bench.effectsRecipe.filmID), canvas: canvas) }
        precondition(first != nil)
        Bench.row("b. open: ImageIO thumbnail decode", String(format: "%8.1f ms", thumbMs))
        Bench.row("b. open: first displayable preview (thumb+first render)", String(format: "%8.1f ms", thumbMs + firstMs))
        let (full, fullMs) = Bench.time { ImageSource.loadDecoded(url: jpeg)! }
        Bench.row("b. open: full-res source decoded", String(format: "%8.1f ms", fullMs))
        engine.setSource(full)
        let (swap, swapMs) = Bench.time { engine.render(Recipe(filmID: Bench.effectsRecipe.filmID), canvas: canvas) }
        precondition(swap != nil)
        Bench.row("b. open: first frame from full-res (base build + render)", String(format: "%8.1f ms", swapMs))

        // a. preview frames
        for (name, canvasSize) in [("1500x1000", canvas), ("2400x1600", CGSize(width: 2400, height: 1600))] {
            for (label, base) in [("effects", Bench.effectsRecipe), ("crop+6deg", Bench.cropRecipe())] {
                var first = 0.0
                var samples: [Double] = []
                for i in 0..<61 {
                    var r = base
                    r.exposure = -1 + 2 * Double(i) / 60
                    let (frame, ms) = Bench.time { engine.render(r, canvas: canvasSize) }
                    precondition(frame != nil)
                    if i == 0 { first = ms } else { samples.append(ms) }
                }
                let s = Bench.stats(samples)
                Bench.row("a. preview frame \(name), \(label)",
                          String(format: "median %7.1f ms   p95 %7.1f ms   (first, base build: %.1f ms)", s.median, s.p95, first))
            }
        }

        // a'. stage breakdown on the cached base
        let film = Bench.effectsRecipe.filmID
        let parts: [(String, Recipe)] = [
            ("no film, exposure only", Recipe(exposure: 0.3)),
            ("film only", Recipe(filmID: film)),
            ("film + exposure/contrast/sat/warmth", Recipe(filmID: film, exposure: 0.3, contrast: 0.2, saturation: 0.2, warmth: 0.2)),
            ("film + grain 0.4", Recipe(filmID: film, grainAmount: 0.4)),
            ("film + halation 0.3", Recipe(filmID: film, halationAmount: 0.3)),
            ("film + bloom 0.2", Recipe(filmID: film, bloomAmount: 0.2)),
            ("film + vignette 0.3", Recipe(filmID: film, vignetteAmount: 0.3)),
            ("all effects", Bench.effectsRecipe),
        ]
        for (label, base) in parts {
            _ = engine.render(base, canvas: canvas)
            var samples: [Double] = []
            for i in 0..<40 {
                var r = base
                r.exposure += 0.01 * Double(i % 7)
                let (_, ms) = Bench.time { engine.render(r, canvas: canvas) }
                samples.append(ms)
            }
            Bench.row("   stage: " + label, String(format: "median %7.1f ms", Bench.stats(samples).median))
        }
        // Same, one context with intermediate caching on
        let cached = PreviewEngine(renderer: renderer, context: Renderer.makeContext(cacheIntermediates: true))
        cached.setSource(full)
        _ = cached.render(Bench.effectsRecipe, canvas: canvas)
        var cachedSamples: [Double] = []
        for i in 0..<60 {
            var r = Bench.effectsRecipe
            r.exposure = -1 + 2 * Double(i) / 59
            cachedSamples.append(Bench.time { cached.render(r, canvas: canvas) }.1)
        }
        let cs = Bench.stats(cachedSamples)
        Bench.row("   effects with cacheIntermediates: true", String(format: "median %7.1f ms   p95 %7.1f ms", cs.median, cs.p95))

        // c. thumbnails
        for (label, mode) in [("c. 32 thumbnails, cold LUT cache", 0), ("c. 32 thumbnails, warm disk LUT cache", 1), ("c. 32 thumbnails, hot (LUTs in memory)", 2)] {
            let cache = benchDir.appendingPathComponent("lut-cache-thumbs-current", isDirectory: true)
            if mode == 0 { try? FileManager.default.removeItem(at: cache) }
            let lib = mode == 2 ? library : try FilmLibrary(directory: filmsURL, cacheDirectory: cache)
            if mode == 2 { lib.prewarmSync() }
            let eng = PreviewEngine(renderer: Renderer(library: lib), context: Renderer.sharedContext)
            eng.setSource(full)
            let ids: [String?] = [nil] + lib.films.map { Optional($0.id) }
            let count = BenchCounter()
            let (_, ms) = Bench.time {
                eng.renderThumbnails(ids: ids, crop: .identity, longSide: 256, workers: 4) { _, _ in count.bump() }
            }
            Bench.row(label, String(format: "%8.0f ms   (\(count.value) thumbnails)", ms))
        }

        // d. export
        let out = benchDir.appendingPathComponent("export-current.jpg")
        let lazy = ImageSource.load(url: jpeg)!
        for (label, src) in [("decoded CGImage source", full), ("lazy file-backed source", lazy), ("decoded CGImage source", full), ("lazy file-backed source", lazy)] {
            let (_, exportMs) = try Bench.time {
                try renderer.export(Bench.effectsRecipe, source: src, metadataFrom: jpeg, outputURL: out, type: .jpeg, quality: 0.95)
            }
            Bench.row("d. export 24 MP JPEG, \(label)", String(format: "%8.0f ms", exportMs))
        }
        try? FileManager.default.removeItem(at: out)
        print("")
    }
}

final class BenchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
