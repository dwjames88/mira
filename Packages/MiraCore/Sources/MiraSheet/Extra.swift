import CoreGraphics
import CoreImage
import Foundation
import MiraCore

/// Film switching, histogram and launch-time work.
enum Extra {
    static func run(library: FilmLibrary, full: CIImage, filmsURL: URL, benchDir: URL) throws {
        print("== switching, histogram, launch ==")
        let canvas = Bench.canvasPixels
        let engine = PreviewEngine(renderer: Renderer(library: library), context: Renderer.sharedContext)
        engine.setSource(full)
        library.prewarmSync()
        let ids = library.films.map(\.id)
        _ = engine.render(Recipe(filmID: ids[0]), canvas: canvas)

        // Same film, exposure moving (the slider-drag case), for reference next to the switch case.
        var same: [Double] = []
        for i in 0..<64 {
            same.append(Bench.time { engine.render(Recipe(filmID: ids[0], exposure: -1 + Double(i) / 32), canvas: canvas) }.1)
        }
        Bench.row("e. slider tick, same film (film only + exposure)", String(format: "median %7.1f ms", Bench.stats(same).median))

        // Film switch: a different film every frame, cycling through all of them.
        var switchSamples: [Double] = []
        for i in 0..<(ids.count * 3) {
            var r = Bench.effectsRecipe
            r.filmID = ids[i % ids.count]
            let (_, ms) = Bench.time { engine.render(r, canvas: canvas) }
            if i >= ids.count { switchSamples.append(ms) }
        }
        let sw = Bench.stats(switchSamples)
        Bench.row("e. film switch, effects recipe, every frame new film", String(format: "median %7.1f ms   p95 %7.1f ms", sw.median, sw.p95))
        var switchBare: [Double] = []
        for i in 0..<(ids.count * 3) {
            let (_, ms) = Bench.time { engine.render(Recipe(filmID: ids[i % ids.count]), canvas: canvas) }
            if i >= ids.count { switchBare.append(ms) }
        }
        let sb = Bench.stats(switchBare)
        Bench.row("e. film switch, film only, every frame new film", String(format: "median %7.1f ms   p95 %7.1f ms", sb.median, sb.p95))

        // Histogram of a canvas-size frame.
        if let frame = engine.render(Bench.effectsRecipe, canvas: canvas) {
            _ = HistogramData.compute(frame: frame)
            var h: [Double] = []
            for _ in 0..<60 { h.append(Bench.time { HistogramData.compute(frame: frame) }.1) }
            let hs = Bench.stats(h)
            Bench.row("f. histogram of a 1536x1024 frame", String(format: "median %7.2f ms   p95 %7.2f ms", hs.median, hs.p95))
        }

        // Launch: library init (films.json), then prewarm cold / warm disk cache.
        let cache = benchDir.appendingPathComponent("lut-cache-launch", isDirectory: true)
        try? FileManager.default.removeItem(at: cache)
        let (_, initMs) = try Bench.time { _ = try FilmLibrary(directory: filmsURL, cacheDirectory: cache) }
        Bench.row("g. launch: FilmLibrary init (films.json)", String(format: "%8.1f ms", initMs))
        for (label, workers, wipe) in [("cold disk cache, 4 workers", 4, true), ("cold disk cache, 10 workers", 10, true),
                                       ("cold disk cache, 4 workers", 4, true), ("cold disk cache, 10 workers", 10, true),
                                       ("warm disk cache, 4 workers", 4, false), ("warm disk cache, 10 workers", 10, false)] {
            if wipe { try? FileManager.default.removeItem(at: cache) }
            let lib = try FilmLibrary(directory: filmsURL, cacheDirectory: cache)
            let (_, ms) = Bench.time { lib.prewarmSync(concurrency: workers) }
            Bench.row("g. launch: prewarm all LUTs, \(label)", String(format: "%8.0f ms", ms))
        }
        // First film-strip render on a freshly prewarmed library (shader compile included).
        let lib = try FilmLibrary(directory: filmsURL, cacheDirectory: cache)
        lib.prewarmSync()
        let ctx = Renderer.makeContext()
        let eng = PreviewEngine(renderer: Renderer(library: lib), context: ctx)
        eng.setSource(full)
        let (_, firstMs) = Bench.time { eng.render(Bench.effectsRecipe, canvas: canvas) }
        Bench.row("g. launch: first frame on a brand-new CIContext", String(format: "%8.1f ms", firstMs))
        print("")
    }

    /// First preview frame of a brand-new process. `MIRA_BENCH_WARMUP=1` runs the launch warm-up first.
    static func coldStart(library: FilmLibrary, jpeg: URL) throws {
        let warm = ProcessInfo.processInfo.environment["MIRA_BENCH_WARMUP"] == "1"
        library.prewarmSync()
        let canvas = Bench.canvasPixels
        let thumb = ImageSource.loadThumbnail(url: jpeg, maxPixelSize: max(canvas.width, canvas.height))!
        var warmMs = 0.0
        if warm { warmMs = Bench.time { PreviewEngine.warmUp(library: library) }.1 }
        let engine = PreviewEngine(renderer: Renderer(library: library), context: Renderer.sharedContext)
        engine.setSource(thumb)
        let (_, firstMs) = Bench.time { engine.render(Bench.gradeRecipe, canvas: canvas) }
        let (_, secondMs) = Bench.time { engine.render(Bench.gradeRecipe, canvas: canvas) }
        print(String(format: "cold start (warm-up %@, %.0f ms): first frame %.1f ms, second %.1f ms",
                     warm ? "on" : "off", warmMs, firstMs, secondMs))
    }
}
