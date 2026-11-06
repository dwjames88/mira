import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Opt-in timing harness for the model and the SwiftUI tree. Off unless `MIRA_PERF=1`:
///
///     cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter UIPerf
///
/// Drives a real `EditorModel` with the bundled films and a 6000x4000 synthetic photo and prints
/// medians (also written to `build/perf-ui.txt`).
@MainActor
@Suite("UIPerf", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MIRA_PERF"] == "1"))
struct UIPerfTests {
    static var report = ""

    static func line(_ label: String, _ value: String) {
        let l = label.padding(toLength: 62, withPad: " ", startingAt: 0) + value
        print(l)
        report += l + "\n"
    }

    static func median(_ s: [Double]) -> Double { s.isEmpty ? 0 : s.sorted()[s.count / 2] }
    static func p95(_ s: [Double]) -> Double {
        let v = s.sorted(); return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * 0.95))]
    }
    static func ms(_ from: ContinuousClock.Instant) -> Double {
        let d = from.duration(to: .now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func syntheticPhoto() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-perf-24mp.jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let fixture = SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")
        var image = CIImage(contentsOf: fixture)!
        let target = CGSize(width: 6000, height: 4000)
        let s = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: CGRect(origin: .zero, size: target))
        try Renderer.sharedContext.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    static func waitUntil(_ timeout: Double = 60, _ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            if Self.ms(start) > timeout * 1000 { return false }
            await Task.yield()
        }
        return true
    }

    @Test func sliderAndFilmTiming() async throws {
        FieldFramesTheme.registerFonts()
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        library.prewarmSync()
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: try Self.syntheticPhoto()))
        model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
        #expect(await Self.waitUntil { model.isSourceFull && model.previewImage != nil && model.isPreviewIdle
            && model.thumbnailsSettled })
        Self.report = ""
        Self.line("mira UI perf", "6000x4000 source, canvas 1500x1000, \(library.films.count) films")
        model.recipe = Recipe(filmID: "fuji-velvia-50", grainAmount: 0.4, halationAmount: 0.3, bloomAmount: 0.2, vignetteAmount: 0.3)
        #expect(await Self.waitUntil { model.isPreviewIdle })

        // Recipe change -> published frame, one change at a time (no coalescing).
        var frame: [Double] = []
        var hist: [Double] = []
        for i in 0..<60 {
            let before = model.publishedFrames
            let t0 = ContinuousClock.now
            model.recipe.exposure = -1 + 2 * Double(i) / 59
            #expect(await Self.waitUntil { model.publishedFrames > before })
            let tFrame = Self.ms(t0)
            model.histogramFrameChanged(model.displayedFrame)
            let h0 = model.histogram
            let tH = ContinuousClock.now
            #expect(await Self.waitUntil(5) { model.histogram != h0 })
            if i >= 5 { frame.append(tFrame); hist.append(Self.ms(tH)) }
        }
        Self.line("slider change -> published preview frame", String(format: "median %6.1f ms  p95 %6.1f ms", Self.median(frame), Self.p95(frame)))
        Self.line("frame -> histogram ready (incl. 20 Hz pacing)", String(format: "median %6.1f ms  p95 %6.1f ms", Self.median(hist), Self.p95(hist)))

        // Film switch, a different film each time.
        let ids = library.films.map(\.id)
        var sw: [Double] = []
        for i in 0..<(ids.count * 2) {
            let before = model.publishedFrames
            let t0 = ContinuousClock.now
            model.recipe.filmID = ids[i % ids.count]
            #expect(await Self.waitUntil { model.publishedFrames > before })
            if i >= ids.count { sw.append(Self.ms(t0)) }
        }
        Self.line("film switch -> published preview frame", String(format: "median %6.1f ms  p95 %6.1f ms", Self.median(sw), Self.p95(sw)))

        // Burst: 120 changes with no waiting; time to the settled frame and frames actually rendered.
        let before = model.publishedFrames
        let t0 = ContinuousClock.now
        for i in 0..<120 { model.recipe.exposure = -1 + 2 * Double(i) / 119 }
        #expect(await Self.waitUntil { model.isPreviewIdle })
        Self.line("burst of 120 slider changes -> settled",
                  String(format: "%6.1f ms, %d frames rendered", Self.ms(t0), model.publishedFrames - before))

        // SwiftUI cost per slider tick: the editor in a hosting view, recipe mutated, tree laid out.
        let host = NSHostingView(rootView: EditorView(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        #expect(await Self.waitUntil { model.isPreviewIdle })
        for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
        // The slider lives on DEVELOP, but the editor opens on FILMS: measure the tick on both tabs.
        for tab in [EditorTab.develop, EditorTab.films] {
            model.selectTab(tab)
            #expect(await Self.waitUntil { model.isPreviewIdle })
            for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
            var ui: [Double] = []
            var cards = 0, strips = 0, sliders = 0, panels = 0, recipeSliders = 0
            let n = 60
            for i in 0..<n {
                let c0 = PerfCounters.filmCard, s0 = PerfCounters.filmStrip
                let sl0 = PerfCounters.slider, p0 = PerfCounters.developPanel, rs0 = PerfCounters.recipeSlider
                let t = ContinuousClock.now
                model.recipe.contrast = Double(i % 20) / 40
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let dt = Self.ms(t)
                cards += PerfCounters.filmCard - c0; strips += PerfCounters.filmStrip - s0
                sliders += PerfCounters.slider - sl0; panels += PerfCounters.developPanel - p0; recipeSliders += PerfCounters.recipeSlider - rs0
                ui.append(dt)
                // Let the render finish between ticks so renders do not pollute the next measurement.
                _ = await Self.waitUntil { model.isPreviewIdle }
                host.layoutSubtreeIfNeeded()
            }
            let name = tab == .develop ? "DEVELOP tab" : "FILMS tab"
            Self.line("SwiftUI per slider tick, \(name) (mutate + layout + display)", String(format: "median %6.2f ms  p95 %6.2f ms", Self.median(ui), Self.p95(ui)))
            Self.line("film strip body evaluations per tick, \(name)", String(format: "%.2f strip, %.1f cards", Double(strips) / Double(n), Double(cards) / Double(n)))
            Self.line("slider / Develop panel body evaluations per tick, \(name)", String(format: "%.1f FFSlider, %.1f RecipeSlider, %.2f panel", Double(sliders) / Double(n), Double(recipeSliders) / Double(n), Double(panels) / Double(n)))
        }

        // Thumbnails arriving one by one: SwiftUI cost of the whole batch.
        // The film strip refilling after a crop: thumbnails arrive one at a time.
        let c0 = PerfCounters.filmCard, s0 = PerfCounters.filmStrip
        let tb = ContinuousClock.now
        let old = model.thumbnails
        model.recipe.crop.rect = CropRect(x: 0.1, y: 0.1, w: 0.7, h: 0.7)
        while Self.ms(tb) < 60_000,
              !(model.thumbnailsSettled && model.thumbnails.allSatisfy { old[$0.key] !== $0.value }) {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        host.layoutSubtreeIfNeeded()
        Self.line("thumbnail batch after a crop (to last card)", String(format: "%6.0f ms, %d strip / %d card body evals",
                  Self.ms(tb), PerfCounters.filmStrip - s0, PerfCounters.filmCard - c0))
        let dir = SnapshotTests.root.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.report.write(to: dir.appendingPathComponent("perf-ui.txt"), atomically: true, encoding: .utf8)
        model.cancelWork()
        window.contentView = nil
    }

    /// Slider-to-frame latency on a RAW file (the iPhone XS DNG fixture): the develop sliders re-render
    /// the graded frame from the cached developed source, a RAW slider re-develops it. Skipped without the fixture.
    @Test func rawSliderLatency() async throws {
        let dng = SnapshotTests.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        try #require(FileManager.default.fileExists(atPath: dng.path), "Fixtures/raw/iphone-xs.dng is not present")
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        library.prewarmSync()
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: dng))
        model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
        #expect(await Self.waitUntil { model.isRawSource && model.isSourceFull && model.previewImage != nil && model.isPreviewIdle })
        #expect(await Self.waitUntil { model.rawSession.refinedKey != nil })
        model.recipe = Recipe(filmID: "fuji-velvia-50", grainAmount: 0.4, halationAmount: 0.3)
        #expect(await Self.waitUntil { model.isPreviewIdle })
        Self.report = ""
        Self.line("mira UI perf, RAW", "iphone-xs.dng, canvas 1500x1000")
        var develop: [Double] = []
        for i in 0..<40 {
            let before = model.publishedFrames
            let t0 = ContinuousClock.now
            model.recipe.exposure = -1 + 2 * Double(i) / 39
            #expect(await Self.waitUntil { model.publishedFrames > before })
            if i >= 5 { develop.append(Self.ms(t0)) }
        }
        Self.line("RAW: exposure slider -> published frame", String(format: "median %6.1f ms  p95 %6.1f ms", Self.median(develop), Self.p95(develop)))
        var raw: [Double] = []
        for i in 0..<12 {
            let before = model.publishedFrames
            let t0 = ContinuousClock.now
            model.recipe.raw.temperature = 4500 + 150 * Double(i)
            #expect(await Self.waitUntil(60) { model.publishedFrames > before && model.isPreviewIdle
                && model.rawSession.refinedKey == RawDevelopKey(model.recipe) })
            raw.append(Self.ms(t0))
        }
        Self.line("RAW: white balance slider -> settled frame", String(format: "median %6.1f ms  p95 %6.1f ms", Self.median(raw), Self.p95(raw)))
        let dir = SnapshotTests.root.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.report.write(to: dir.appendingPathComponent("perf-ui-raw.txt"), atomically: true, encoding: .utf8)
        model.cancelWork()
    }
}
