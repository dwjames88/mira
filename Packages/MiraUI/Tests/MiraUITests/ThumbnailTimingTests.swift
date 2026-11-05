import CoreImage
import Foundation
import MiraCore
import Testing
@testable import MiraUI

/// Opt-in (`MIRA_PERF=1`): time to the first 8 film-strip thumbnails and to all of them under "All",
/// before (every card, no disk cache) and after (lazy window, cold and warm disk cache). Writes
/// `build/perf-thumbnails.txt`.
@MainActor
@Suite("Thumbnail timing", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MIRA_PERF"] == "1"))
struct ThumbnailTimingTests {
    struct Result { var first8 = 0.0, settled = 0.0, all = 0.0; var renders = 0 }

    static func run(library: FilmLibrary, cache: ThumbnailDiskCache?, all: Bool, lazyOnly: Bool = false) async throws -> Result {
        let model = EditorModel(library: library)
        model.thumbnailDiskCache = cache
        model.setCanvas(pixels: CGSize(width: 1200, height: 800))
        model.thumbnailDemandAll = all
        let t0 = ContinuousClock.now
        #expect(model.loadSource(url: SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")))
        var r = Result()
        func ms() -> Double { let d = t0.duration(to: .now); return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var got8 = false, gotSettled = false
        while !(all ? model.thumbnailsSettled : gotSettled) {
            if !got8, model.thumbnails.count >= 8 { got8 = true; r.first8 = ms() }
            if !gotSettled, model.thumbnailsSettled { gotSettled = true; r.settled = ms() }
            if ms() > 600_000 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        if !got8 { r.first8 = ms() }
        if !gotSettled { r.settled = ms() }
        if !all {
            // Then everything under All, as if the user scrolled the whole strip.
            let t1 = ContinuousClock.now
            model.loadAllThumbnails()
            while !model.thumbnailsSettled, t1.duration(to: .now) < .seconds(600) { try await Task.sleep(for: .milliseconds(2)) }
            let d = t1.duration(to: .now)
            r.all = r.settled + Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        } else {
            r.all = r.settled
        }
        r.renders = model.engine.thumbnailRenderCount
        model.cancelWork()
        return r
    }

    @Test func firstEightAndAll() async throws {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"),
                                      cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mira-perf-luts"))
        library.prewarmSync()   // LUT decode is paid at launch by the app; keep it out of these numbers
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-perf-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines = ["thumbnail timing, Fixtures/sample.jpg, \(library.stocks.count) stocks + Original, canvas 1200x800",
                     "(ms from loadSource; LUTs prewarmed; medians of 3)"]
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        func row(_ name: String, _ rs: [Result]) {
            lines.append(String(format: "%-44@ first 8: %7.0f   window/settled: %7.0f   all: %7.0f   renders: %d",
                                name as NSString, median(rs.map(\.first8)), median(rs.map(\.settled)), median(rs.map(\.all)), rs[0].renders))
        }
        var before: [Result] = []
        for _ in 0..<3 { before.append(try await Self.run(library: library, cache: nil, all: true)) }
        row("before: every card, no disk cache", before)
        var cold: [Result] = [], warm: [Result] = []
        for _ in 0..<3 {
            let cache = ThumbnailDiskCache(directory: dir.appendingPathComponent(UUID().uuidString))
            cold.append(try await Self.run(library: library, cache: cache, all: false))
            warm.append(try await Self.run(library: library, cache: cache, all: false))
        }
        row("after: lazy window + disk cache, cold", cold)
        row("after: lazy window + disk cache, warm", warm)
        let out = lines.joined(separator: "\n") + "\n"
        print(out)
        let build = SnapshotTests.root.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try? out.write(to: build.appendingPathComponent("perf-thumbnails.txt"), atomically: true, encoding: .utf8)
    }
}
