import CoreGraphics
import CoreImage
import Foundation
import MiraCore

/// h. Dodge and burn at the preview size (canvas 1500x1000 of the 6000x4000 photo).
enum DodgeBurnBench {
    static let source = CGSize(width: 6000, height: 4000)
    static let size = CGSize(width: 1500, height: 1000)

    /// A wandering stroke of `points` points; `seed` moves it about.
    static func stroke(_ seed: Int, points: Int = 40, mode: DodgeBurnMode = .dodge, size: Double = 0.1) -> DodgeBurnStroke {
        var pts: [StrokePoint] = []
        var x = 0.15 + 0.7 * Double((seed * 37) % 100) / 100
        var y = 0.15 + 0.7 * Double((seed * 61) % 100) / 100
        for i in 0..<points {
            x += 0.012 * cos(Double(i + seed) * 0.3)
            y += 0.009 * sin(Double(i + seed) * 0.25)
            pts.append(StrokePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1), pressure: 0.6 + 0.4 * sin(Double(i) * 0.2)))
        }
        return DodgeBurnStroke(mode: mode, points: pts, size: size, feather: 0.6, flow: 0.4, strength: 0.7)
    }

    static func settings(_ count: Int) -> DodgeBurnSettings {
        DodgeBurnSettings(strokes: (0..<count).map { stroke($0, mode: $0 % 3 == 2 ? .burn : .dodge) })
    }

    static func run(renderer: Renderer, context: CIContext, jpeg: URL) throws {
        print("== dodge & burn (mask at \(Int(size.width))x\(Int(size.height))) ==")
        for count in [1, 10, 50] {
            let s = settings(count)
            _ = Renderer.rasterizeDodgeBurnMasks(s, crop: .identity, sourceSize: source, size: size)
            var samples: [Double] = []
            for _ in 0..<10 {
                let (_, ms) = Bench.time { Renderer.rasterizeDodgeBurnMasks(s, crop: .identity, sourceSize: source, size: size) }
                samples.append(ms)
            }
            let st = Bench.stats(samples)
            Bench.row("h. mask rasterisation, \(count) stroke\(count == 1 ? "" : "s") (cold)",
                      String(format: "median %7.2f ms   p95 %7.2f ms", st.median, st.p95))
        }

        // A live stroke: the 10 committed strokes are cached, one point added per call.
        var live = stroke(99, points: 1, size: 0.1)
        let committed = settings(10)
        var base = committed
        base.strokes.append(live)
        renderer.prepareDodgeBurnMasks(base, crop: .identity, sourceSize: source, size: size)
        var samples: [Double] = []
        let template = stroke(99, points: 60, size: 0.1)
        for i in 1..<60 {
            live.points = Array(template.points.prefix(i + 1))
            var s = committed
            s.strokes.append(live)
            let (_, ms) = Bench.time { renderer.prepareDodgeBurnMasks(s, crop: .identity, sourceSize: source, size: size) }
            samples.append(ms)
        }
        let st = Bench.stats(samples)
        Bench.row("h. live stroke update, +1 point on 10 cached (mask only)",
                  String(format: "median %7.2f ms   p95 %7.2f ms", st.median, st.p95))

        // Graded frames at preview size, through the whole graph.
        guard let full = ImageSource.load(url: jpeg) else { return }
        let preview = renderer.previewImage(from: full, maxPixelSize: 1500)
        let film = Bench.effectsRecipe
        for (label, count) in [("no strokes", 0), ("10 strokes", 10), ("50 strokes", 50)] {
            var r = film
            r.dodgeBurn = settings(count)
            _ = renderer.render(r, input: preview, context: context)
            var frames: [Double] = []
            for i in 0..<30 {
                r.exposure = 0.01 * Double(i % 5)
                let (_, ms) = Bench.time { renderer.render(r, input: preview, context: context) }
                frames.append(ms)
            }
            Bench.row("h. graded frame, effects recipe + \(label)", String(format: "median %7.1f ms", Bench.stats(frames).median))
        }
        // A painting frame: 10 strokes cached, the live stroke grows by one point each frame.
        var r = film
        var frames: [Double] = []
        var stroke = template
        let ten = settings(10)
        for i in 1..<60 {
            stroke.points = Array(template.points.prefix(i + 1))
            r.dodgeBurn = ten
            r.dodgeBurn.strokes.append(stroke)
            let (_, ms) = Bench.time { renderer.render(r, input: preview, context: context) }
            frames.append(ms)
        }
        let f = Bench.stats(frames)
        Bench.row("h. painting frame (10 cached + live stroke, full graph)",
                  String(format: "median %7.1f ms   p95 %7.1f ms", f.median, f.p95))
        print("")
    }
}
