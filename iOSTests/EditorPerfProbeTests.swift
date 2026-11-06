import CoreImage
import MiraCore
import UIKit
import XCTest
@testable import Mira

/// Opt-in editor timings (`TEST_RUNNER_MIRA_EDITOR_PERF=1`): open, slider-to-frame, an idle redraw and the histogram.
/// Prints `EDITORPERF name median_ms (min..max)` lines; the numbers depend on the machine and its load.
@MainActor
final class EditorPerfProbeTests: XCTestCase {
    static let ink = CIColor(red: 0.082, green: 0.078, blue: 0.059)
    static let drawable = CGSize(width: 1179, height: 1800)

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_EDITOR_PERF"] == "1", "opt-in: MIRA_EDITOR_PERF=1")
    }

    private func report(_ name: String, _ samples: [Double]) {
        let s = samples.sorted()
        print(String(format: "EDITORPERF %@ median %.2f ms (min %.2f, max %.2f, n %d)", name, s[s.count / 2], s.first!, s.last!, s.count))
    }

    private func time(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    private func jpeg12MP() throws -> Data {
        let w = 4032, h = 3024
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.darkGray.cgColor, UIColor.orange.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            for i in 0..<400 {
                cg.setFillColor(UIColor(hue: CGFloat(i % 20) / 20, saturation: 0.7, brightness: 0.8, alpha: 1).cgColor)
                cg.fill(CGRect(x: (i * 97) % w, y: (i * 53) % h, width: 200, height: 120))
            }
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    func testEditorTimings() async throws {
        let data = try jpeg12MP()
        let engine = PhotoEngine()
        var loadSamples: [Double] = []
        var loaded: LoadedSource?
        for i in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            loaded = try await engine.load(data: data, epoch: i + 1)
            loadSamples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        report("engine.load 12MP JPEG", loadSamples)
        let source = try XCTUnwrap(loaded)

        // Histogram: repeated like the 10 Hz drag.
        var recipe = Recipe(filmID: StepConsistencyTests.film(mono: false).id)
        _ = try await engine.histogram(for: recipe)
        var histo: [Double] = []
        for i in 0..<15 {
            recipe.exposure = Double(i) * 0.02
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try await engine.histogram(for: recipe)
            histo.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        report("engine.histogram (12MP source, film)", histo)
        var thumbs: [Double] = []
        for _ in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try await engine.renderThumbnail(filmID: StepConsistencyTests.film(mono: false).id)
            thumbs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        report("engine.renderThumbnail (12MP source, film)", thumbs)

        // Open: present + first frame (proxy built on the main thread).
        var open: [Double] = []
        var firstFrame: [Double] = []
        for _ in 0..<5 {
            let m = EditorViewModel()
            m.live.proxyBox = CGSize(width: 1179, height: 2556)
            open.append(time { m.present(source) })
            m.select(StepConsistencyTests.film(mono: false).id)
            firstFrame.append(time {
                _ = DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, contentScale: 3, ink: Self.ink)
            })
        }
        report("present(12MP)", open)
        report("first frame incl. proxy build", firstFrame)

        let m = EditorViewModel()
        m.live.proxyBox = CGSize(width: 1179, height: 2556)
        m.present(source)
        m.select(StepConsistencyTests.film(mono: false).id)
        _ = DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, contentScale: 3, ink: Self.ink)
        var slider: [Double] = []
        for i in 0..<25 {
            m.recipe.exposure = 0.05 * Double(i % 10) + 0.01
            slider.append(time {
                _ = DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, contentScale: 3, ink: Self.ink)
            })
        }
        report("slider tick -> frame (grade + resample + readback)", slider)
        var idle: [Double] = []
        for _ in 0..<25 {
            idle.append(time {
                _ = DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, contentScale: 3, ink: Self.ink)
            })
        }
        report("idle redraw, same recipe (+readback)", idle)
        var graph: [Double] = []
        for _ in 0..<50 {
            graph.append(time { _ = m.live.gradedImage(for: m.liveRecipe, cropping: false, showingOriginal: false) })
        }
        report("gradedImage graph build only", graph)
    }
}
