import CoreImage
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Opt-in: a simulated 60-point painting drag on a 24 MP photo, one point per frame, measuring the time
/// from the pointer move to the published frame. Off unless `MIRA_PERF=1`:
///
///     cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter DodgeBurnPerf
///
/// Writes `build/perf-dodgeburn.txt`.
@MainActor
@Suite("DodgeBurnPerf", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MIRA_PERF"] == "1"))
struct DodgeBurnPerfTests {
    @Test func paintingDragTiming() async throws {
        FieldFramesTheme.registerFonts()
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        library.prewarmSync()
        let model = EditorModel(library: library, presetStore: PresetModelTests.tempStore())
        #expect(model.loadSource(url: try UIPerfTests.syntheticPhoto()))
        model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
        model.setViewport(pane: CGSize(width: 1500, height: 1000), fitArea: CGSize(width: 1500, height: 1000))
        #expect(await UIPerfTests.waitUntil { model.isSourceFull && model.previewImage != nil && model.isPreviewIdle })
        model.recipe = Recipe(filmID: "fuji-velvia-50", grainAmount: 0.4, halationAmount: 0.3, bloomAmount: 0.2, vignetteAmount: 0.3)
        #expect(await UIPerfTests.waitUntil { model.isPreviewIdle })
        model.setDodgeBurnTool(true)
        model.setPaint(\.size, 0.1)

        var lines: [String] = []
        for (label, committed) in [("empty photo", 0), ("10 strokes already painted", 10)] {
            model.clearAllStrokes()
            for i in 0..<committed {
                let y = 300 + Double(i) * 40
                #expect(model.beginPaintStroke(atPane: CGPoint(x: 300, y: y)))
                for k in 1...20 { model.continuePaintStroke(atPane: CGPoint(x: 300 + Double(k) * 20, y: y + Double(k % 3) * 5)) }
                model.endPaintStroke()
            }
            #expect(await UIPerfTests.waitUntil { model.isPreviewIdle })
            var samples: [Double] = []
            #expect(model.beginPaintStroke(atPane: CGPoint(x: 400, y: 500)))
            for i in 1...60 {
                let before = model.publishedFrames
                let t0 = ContinuousClock.now
                model.continuePaintStroke(atPane: CGPoint(x: 400 + Double(i) * 14, y: 500 + 60 * sin(Double(i) * 0.2)))
                #expect(await UIPerfTests.waitUntil { model.publishedFrames > before })
                samples.append(UIPerfTests.ms(t0))
            }
            model.endPaintStroke()
            #expect(await UIPerfTests.waitUntil { model.isPreviewIdle })
            lines.append("painting frame, \(label): median \(String(format: "%.1f", UIPerfTests.median(samples))) ms, p95 \(String(format: "%.1f", UIPerfTests.p95(samples))) ms")
        }
        let text = "mira dodge & burn perf: 6000x4000 source, canvas 1500x1000, 60-point drag\n" + lines.joined(separator: "\n") + "\n"
        print(text)
        let dir = SnapshotTests.root.appendingPathComponent("build", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("perf-dodgeburn.txt"), atomically: true, encoding: .utf8)
        model.cancelWork()
    }
}
