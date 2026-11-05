import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MiraCore

/// Open-time measurements for RAW files. Skipped unless `MIRA_BENCH_RAW=1` (it prints, it does not assert
/// speed). `MIRA_RAW_DIR` points at the folder holding sony-ilce7m3.arw. Medians of 3 runs, milliseconds.
@Suite("RAW open benchmark", .serialized)
struct RawOpenBenchmark {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MIRA_BENCH_RAW"] == "1" }

    private static func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    /// (first run, median of 3). Run each phase in its own process (MIRA_BENCH_PHASE) so the first
    /// run is a cold decode, not one that reuses the system's decoded-data cache from an earlier phase.
    private static func timed(_ body: () -> Void) -> String {
        let runs = (0..<3).map { _ in ms(body) }
        return String(format: "%.0f ms cold, %.0f ms median", runs[0], runs.sorted()[1])
    }

    /// Forces the pixels of `image` to exist (what the first on-screen frame costs the renderer).
    nonisolated(unsafe) static var fullSizeNote = ""

    @discardableResult
    private static func realise(_ image: CIImage) -> CGSize? {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let e = image.extent.integral
        guard e.width > 0, e.width.isFinite else { return nil }
        let rowBytes = Int(e.width) * 8
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * Int(e.height), alignment: 16)
        defer { buffer.deallocate() }
        RawSamples.context.render(image, toBitmap: buffer, rowBytes: rowBytes, bounds: e, format: .RGBAh, colorSpace: space)
        return e.size
    }

    @Test(arguments: ["iphone-xs.dng", "sony-ilce7m3.arw"])
    func openTimes(_ name: String) throws {
        guard Self.enabled else { return }
        let url = try #require(RawSamples.url(name))
        let settings = RawSettings.identity

        let phase = ProcessInfo.processInfo.environment["MIRA_BENCH_PHASE"] ?? "after"
        if phase == "before" {
            // BEFORE: what EditorModel.loadRawSource did: parse the file, draft decode at preview size, and
            // the renderer's first realisation of it. Every open and every reopen paid this. The only
            // non-draft decode was export's, at full size.
            let first = Self.timed {
                guard let d = RawDevelop(url: url),
                      let img = d.apply(settings, filmApplied: false, draft: true, scale: d.previewScale()) else { return }
                Self.realise(img)
            }
            let full = Self.timed {
                if let img = ImageSource.developedSource(url: url, recipe: Recipe.neutral, draft: false) {
                    if let size = Self.realise(img) { Self.fullSizeNote = "\(Int(size.width))x\(Int(size.height))" }
                }
            }
            var d: RawDevelop?
            let initMs = Self.timed { d = RawDevelop(url: url) }
            let drafted = Self.timed { if let d, let i = d.apply(settings, filmApplied: false, draft: true, scale: d.previewScale()) { Self.realise(i) } }
            let fullScale = Self.timed { if let d, let i = d.apply(settings, filmApplied: false, draft: false, scale: 1) { Self.realise(i) } }
            let fullScaleDraft = Self.timed { if let d, let i = d.apply(settings, filmApplied: false, draft: true, scale: 1) { Self.realise(i) } }
            print("RAWBENCH breakdown \(name): init \(initMs) | draft@preview \(drafted) | nondraft@1.0 \(fullScale) | draft@1.0 \(fullScaleDraft)")
            print("RAWBENCH before \(name): first editable frame (every open and reopen) \(first) | full-size non-draft decode (\(Self.fullSizeNote) px) \(full)")
            return
        }
        // AFTER: embedded preview placeholder, then the draft proxy, then the refine, then a cached reopen.
        let placeholder = Self.timed { _ = ImageSource.loadEmbeddedPreview(url: url).map(Self.realise) }
        let cache = RawAssetCache(capacity: 6, byteBudget: 400 << 20)
        var develop: RawDevelop?
        let draft = Self.timed {
            cache.removeAll()
            develop = RawOpener.openDraft(url: url, orientation: nil, settings: settings, filmApplied: false,
                                          cacheKey: "k", cache: cache)?.develop
        }
        let refine = Self.timed {
            if let d = develop, let r = RawOpener.refine(develop: d, settings: settings, filmApplied: false) { Self.realise(r.image) }
        }
        _ = RawOpener.openDraft(url: url, orientation: nil, settings: settings, filmApplied: false, cacheKey: "k", cache: cache)
        let reopen = Self.timed {
            _ = RawOpener.openDraft(url: url, orientation: nil, settings: settings, filmApplied: false, cacheKey: "k", cache: cache)
        }
        print("RAWBENCH after \(name): placeholder (embedded preview) \(placeholder) | first editable frame (draft proxy) \(draft) | full-quality preview, background \(refine) | reopen from cache \(reopen)")
    }
}
