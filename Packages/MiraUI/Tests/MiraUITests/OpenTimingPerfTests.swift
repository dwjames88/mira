import AppKit
import CoreImage
import Foundation
import ImageIO
import MiraCore
import Testing
import UniformTypeIdentifiers
@testable import MiraUI

/// Opt-in (`MIRA_PERF=1`): how long the editor model takes to show a picture, per file type. For each file it times
/// five fresh `EditorModel` opens (the first is cold for the file and the decoders, the rest warm):
///
///   - `returned`   `loadSource` returns (the stand-in or the embedded RAW preview is already the source)
///   - `first`      the first preview frame is published (`previewImage` is non-nil)
///   - `full`       the full-size source is in (`isSourceFull`); for a RAW also the draft frame
///   - `refined`    RAW only: the full-quality develop has landed (`rawSession.refinedKey`)
///
/// Files: a 6000x4000 JPEG and HEIC made from `Fixtures/sample.jpg`, `Fixtures/raw/iphone-xs.dng`, and, when present
/// in `MIRA_RAW_DIR`, `iphone-12-pro.dng` and `sony-ilce7m3.arw`. Prints and writes `build/perf-open.txt`.
///
///     cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter OpenTimingPerf
@MainActor
@Suite("OpenTimingPerf", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MIRA_PERF"] == "1"))
struct OpenTimingPerfTests {
    static var report = ""

    static func line(_ label: String, _ value: String) {
        let l = label.padding(toLength: 34, withPad: " ", startingAt: 0) + value
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

    /// Peak resident set of this process so far, MB (monotonic).
    static var peakRSSMB: Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576
    }

    static func heic() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-perf-24mp.heic")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let jpeg = try UIPerfTests.syntheticPhoto()
        let src = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(dest, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    static func files() throws -> [(String, URL)] {
        var out: [(String, URL)] = [("JPEG 6000x4000", try UIPerfTests.syntheticPhoto()), ("HEIC 6000x4000", try heic())]
        let fixtures = SnapshotTests.root.appendingPathComponent("Fixtures/raw")
        out.append(("DNG iphone-xs 4032x3024", fixtures.appendingPathComponent("iphone-xs.dng")))
        if let dir = ProcessInfo.processInfo.environment["MIRA_RAW_DIR"] {
            for (label, name) in [("DNG iphone-12-pro", "iphone-12-pro.dng"), ("ARW sony-a7iii 6000x4000", "sony-ilce7m3.arw")] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { out.append((label, url)) }
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    @Test func openTimes() async throws {
        FieldFramesTheme.registerFonts()
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        library.prewarmSync()
        Self.report = ""
        Self.line("mira editor open timings", "ms; run 1 is cold, medians over 5 opens; canvas 1500x1000")
        for (label, url) in try Self.files() {
            let isRaw = ImageSource.isRAW(url: url)
            var returned: [Double] = [], first: [Double] = [], full: [Double] = [], refined: [Double] = []
            for _ in 0..<5 {
                if isRaw { RawAssetCache.shared.removeAll() }
                let model = EditorModel(library: library)
                model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
                let t0 = ContinuousClock.now
                #expect(model.loadSource(url: url))
                returned.append(Self.ms(t0))
                var tFirst: Double?, tFull: Double?, tRefined: Double?
                let deadline = 90_000.0
                while Self.ms(t0) < deadline {
                    if tFirst == nil, model.previewImage != nil { tFirst = Self.ms(t0) }
                    if tFull == nil, model.isSourceFull, (!isRaw || model.isRawSource) { tFull = Self.ms(t0) }
                    if isRaw, tRefined == nil, model.rawSession.refinedKey != nil { tRefined = Self.ms(t0) }
                    if tFirst != nil, tFull != nil, !isRaw || tRefined != nil { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                first.append(tFirst ?? .nan); full.append(tFull ?? .nan)
                if isRaw { refined.append(tRefined ?? .nan) }
                // Let the post-open work (thumbnails, histogram) finish so it does not leak into the next open.
                _ = await UIPerfTests.waitUntil(60) { model.isPreviewIdle && model.thumbnailsSettled }
                model.cancelWork()
            }
            func fmt(_ s: [Double]) -> String {
                String(format: "cold %7.1f  median %7.1f  p95 %7.1f", s[0], Self.median(s), Self.p95(s))
            }
            Self.line("\(label)  returned", fmt(returned))
            Self.line("\(label)  first frame", fmt(first))
            Self.line("\(label)  full source", fmt(full))
            if isRaw { Self.line("\(label)  refined", fmt(refined)) }
            Self.line("\(label)  peak RSS so far", String(format: "%.0f MB", Self.peakRSSMB))
        }
        let dir = SnapshotTests.root.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.report.write(to: dir.appendingPathComponent("perf-open.txt"), atomically: true, encoding: .utf8)
    }
}
