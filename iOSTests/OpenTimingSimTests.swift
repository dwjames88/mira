import CoreImage
import Foundation
import ImageIO
import MiraCore
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Mira

/// Opt-in editor-open timings on the simulator (the Mac GPU/CPU through the simulator, so a proxy for a phone):
/// `TEST_RUNNER_MIRA_PERF=1 xcodebuild test ... -only-testing:MiraiOSTests/OpenTimingSimTests`
/// (add `TEST_RUNNER_MIRA_RAW_DIR=<folder with iphone-12-pro.dng, sony-ilce7m3.arw>` for the extra RAWs).
///
/// PhotoKit is left out on purpose (its fetch latency depends on the simulator's library, and the rules allow PhotoKit
/// tests only on the "Emulsion Test" album): this times what the app does after Photos hands over a file.
///   - JPEG / HEIC (6000x4000): `PhotoEngine.load(data:)`, the import path (decode + the histogram and thumbnail bases)
///   - RAW: `RawOpener.openDraft` (the first editable frame, `AssetEditSession` stage 1), then the full-quality
///     develop that `rawSource(for:full: true)` runs in the background.
/// Five runs each, run 1 cold; prints `OPENTIMING ...` lines and the process's own peak resident size.
final class OpenTimingSimTests: XCTestCase {
    private static func ms(_ from: ContinuousClock.Instant) -> Double {
        let d = from.duration(to: .now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func summary(_ s: [Double]) -> String {
        let v = s.sorted()
        return String(format: "cold %.1f median %.1f p95 %.1f", s[0], v[v.count / 2], v[min(v.count - 1, Int(Double(v.count) * 0.95))])
    }

    private static var peakRSSMB: Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576
    }

    private static func syntheticFiles() throws -> [(String, URL)] {
        let tmp = FileManager.default.temporaryDirectory
        let fixture = Snapshot.root.appendingPathComponent("Fixtures/sample.jpg")
        var image = try XCTUnwrap(CIImage(contentsOf: fixture))
        let target = CGSize(width: 6000, height: 4000)
        let s = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: CGRect(origin: .zero, size: target))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let jpeg = tmp.appendingPathComponent("mira-open-24mp.jpg")
        let heic = tmp.appendingPathComponent("mira-open-24mp.heic")
        let ctx = CIContext()
        try ctx.writeJPEGRepresentation(of: image, to: jpeg, colorSpace: space)
        try ctx.writeHEIFRepresentation(of: image, to: heic, format: .RGBA8, colorSpace: space)
        return [("JPEG 6000x4000", jpeg), ("HEIC 6000x4000", heic)]
    }

    func testOpenTimes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_PERF"] == "1", "set TEST_RUNNER_MIRA_PERF=1")
        var lines: [String] = []
        func emit(_ s: String) { print("OPENTIMING \(s)"); lines.append(s) }
        emit("host \(ProcessInfo.processInfo.operatingSystemVersionString), simulator, 5 runs each, ms")

        for (label, url) in try Self.syntheticFiles() {
            let data = try Data(contentsOf: url)
            var times: [Double] = []
            for _ in 0..<5 {
                let engine = PhotoEngine()
                let t0 = ContinuousClock.now
                let loaded = try await engine.load(data: data)
                times.append(Self.ms(t0))
                XCTAssertGreaterThan(loaded.size.width, 0)
            }
            emit("\(label)  PhotoEngine.load(data:)  \(Self.summary(times))  peak RSS \(Int(Self.peakRSSMB)) MB")
        }

        var raws: [(String, URL)] = [("DNG iphone-xs 4032x3024", Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng"))]
        if let dir = ProcessInfo.processInfo.environment["MIRA_RAW_DIR"] {
            for (label, name) in [("DNG iphone-12-pro", "iphone-12-pro.dng"), ("ARW sony-a7iii", "sony-ilce7m3.arw")] {
                raws.append((label, URL(fileURLWithPath: dir).appendingPathComponent(name)))
            }
        }
        for (label, url) in raws where FileManager.default.fileExists(atPath: url.path) {
            var draft: [Double] = [], full: [Double] = []
            for i in 0..<5 {
                RawAssetCache.shared.removeAll()
                let t0 = ContinuousClock.now
                let frame = try XCTUnwrap(RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false,
                                                              cacheKey: "open-timing-\(i)"))
                draft.append(Self.ms(t0))
                let t1 = ContinuousClock.now
                let refined = RawOpener.refine(develop: frame.develop, settings: .identity, filmApplied: false)
                full.append(Self.ms(t1))
                XCTAssertNotNil(refined)
            }
            emit("\(label)  openDraft (first editable frame)  \(Self.summary(draft))  peak RSS \(Int(Self.peakRSSMB)) MB")
            emit("\(label)  refine (full quality, after draft)  \(Self.summary(full))  peak RSS \(Int(Self.peakRSSMB)) MB")
        }
        let out = Snapshot.root.appendingPathComponent("build/perf-open-ios.txt")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
}
