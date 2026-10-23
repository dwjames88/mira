import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct DodgeBurnMaskTests {
    typealias S = DodgeBurnModelTests

    static func geometry(source: CGSize = CGSize(width: 200, height: 100), crop: CropSettings = .identity,
                         graded: CGSize? = nil) -> DodgeBurnGeometry {
        let out = CropGeometry.outputExtent(for: crop, imageExtent: CGRect(origin: .zero, size: source)).size
        return DodgeBurnGeometry(crop: crop, sourceSize: source, gradedSize: graded ?? out)
    }

    /// The mask value at bitmap pixel (x, y from the top).
    static func value(_ state: DodgeBurnState, _ g: DodgeBurnGeometry, _ x: Int, _ y: Int, layer: Int = 0) -> Float {
        let key = state.order[layer]
        return state.buffers[key]?.values[y * g.width + x] ?? 0
    }

    @Test func strokeIsNonZeroOnlyNearItsPoints() throws {
        let g = Self.geometry()
        // Short side 100, size 0.2 -> 20 px diameter, 10 px radius, at (100, 50).
        let state = DodgeBurnRaster.rasterize([S.stroke(at: [(0.5, 0.5)], size: 0.2, feather: 0)], geometry: g)
        #expect(Self.value(state, g, 100, 50) > 0.99)
        #expect(Self.value(state, g, 104, 52) > 0.99)
        #expect(Self.value(state, g, 120, 50) == 0)
        #expect(Self.value(state, g, 100, 70) == 0)
        #expect(Self.value(state, g, 0, 0) == 0)
        let key = try #require(state.order.first)
        let nonZero = try #require(state.buffers[key]).values.enumerated().filter { $0.element > 0 }
        for (i, _) in nonZero {
            let x = i % g.width, y = i / g.width
            #expect(hypot(Double(x) - 100, Double(y) - 50) < 12)
        }
        #expect(nonZero.count > 250)   // pi * 10^2 = 314
    }

    @Test func featherSoftensTheEdge() {
        let g = Self.geometry()
        let hard = DodgeBurnRaster.rasterize([S.stroke(size: 0.4, feather: 0)], geometry: g)
        let soft = DodgeBurnRaster.rasterize([S.stroke(size: 0.4, feather: 1)], geometry: g)
        // 20 px radius; at 10 px out the soft brush is partway, the hard one is full.
        #expect(Self.value(hard, g, 110, 50) > 0.99)
        let mid = Self.value(soft, g, 110, 50)
        #expect(mid > 0.2 && mid < 0.8)
        #expect(Self.value(soft, g, 100, 50) > 0.99)
    }

    @Test func strengthFlowAndPressureScaleTheMask() {
        let g = Self.geometry()
        let half = DodgeBurnRaster.rasterize([S.stroke(size: 0.2, strength: 0.5, feather: 0)], geometry: g)
        #expect(abs(Self.value(half, g, 100, 50) - 0.5) < 0.01)
        var s = S.stroke(size: 0.2, strength: 1, flow: 0.4, feather: 0)
        let single = DodgeBurnRaster.rasterize([s], geometry: g)
        #expect(abs(Self.value(single, g, 100, 50) - 0.4) < 0.01)
        s.points[0].pressure = 0.5
        let light = DodgeBurnRaster.rasterize([s], geometry: g)
        #expect(abs(Self.value(light, g, 100, 50) - 0.2) < 0.01)
    }

    @Test func overlappingDabsBuildUpWithFlow() {
        let g = Self.geometry()
        let line = S.stroke(at: [(0.3, 0.5), (0.7, 0.5)], size: 0.2, strength: 1, flow: 0.3, feather: 0)
        let state = DodgeBurnRaster.rasterize([line], geometry: g)
        // Many dabs overlap on the line, so the middle is well above one dab's 0.3 yet below 1 + a hair.
        let mid = Self.value(state, g, 100, 50)
        #expect(mid > 0.8 && mid <= 1)
    }

    @Test func eraseReducesAndHiddenContributesNothing() {
        let g = Self.geometry()
        let paint = S.stroke(at: [(0.5, 0.5)], size: 0.3, feather: 0)
        let erase = S.stroke(.erase, at: [(0.5, 0.5)], size: 0.1, feather: 0)
        let both = DodgeBurnRaster.rasterize([paint, erase], geometry: g)
        #expect(Self.value(both, g, 100, 50) < 0.01)      // erased core
        #expect(Self.value(both, g, 100, 62) > 0.99)      // untouched ring
        // Erase only takes away from strokes painted before it.
        let reversed = DodgeBurnRaster.rasterize([erase, paint], geometry: g)
        #expect(Self.value(reversed, g, 100, 50) > 0.99)
        var hidden = paint; hidden.hidden = true
        let settings = DodgeBurnSettings(strokes: [hidden])
        #expect(settings.activeStrokes.isEmpty && !settings.hasVisibleEffect)
        #expect(DodgeBurnRaster.rasterize(settings.activeStrokes, geometry: g).order.isEmpty)
    }

    @Test func burnAndDodgeAreSeparateLayers() {
        let g = Self.geometry()
        let state = DodgeBurnRaster.rasterize([S.stroke(.dodge), S.stroke(.burn, at: [(0.2, 0.5)]),
                                                S.stroke(.dodge, at: [(0.8, 0.5)])], geometry: g)
        #expect(state.order.count == 2)
        var other = S.stroke(.dodge); other.range = .highlights
        #expect(DodgeBurnRaster.rasterize([S.stroke(.dodge), other], geometry: g).order.count == 2)
    }

    @Test func cropMovesStrokesWithThePicture() throws {
        let source = CGSize(width: 400, height: 200)
        // Right half only: output 200 x 200. A stroke at the source's (0.75, 0.5) is its centre.
        var crop = CropSettings(); crop.rect = CropRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let g = Self.geometry(source: source, crop: crop)
        #expect(g.width == 200 && g.height == 200)
        let stroke = S.stroke(at: [(0.75, 0.5)], size: 0.2, feather: 0)   // 40 px diameter
        let state = DodgeBurnRaster.rasterize([stroke], geometry: g)
        #expect(Self.value(state, g, 100, 100) > 0.99)
        #expect(Self.value(state, g, 100, 140) == 0)
        // A stroke in the left half falls outside the crop and leaves no mask.
        #expect(DodgeBurnRaster.rasterize([S.stroke(at: [(0.2, 0.5)], size: 0.2)], geometry: g).order.isEmpty)

        // A quarter turn clockwise puts the source's top-left corner at the top-right.
        var turned = CropSettings(); turned.rotate90 = 1
        let gt = Self.geometry(source: source, crop: turned)
        #expect(gt.width == 200 && gt.height == 400)
        let corner = DodgeBurnRaster.rasterize([S.stroke(at: [(0.1, 0.1)], size: 0.2, feather: 0)], geometry: gt)
        let p = gt.map(StrokePoint(x: 0.1, y: 0.1))
        #expect(abs(p.x - 180) < 0.5 && abs(p.y - 40) < 0.5)
        #expect(Self.value(corner, gt, 180, 40) > 0.99)
        #expect(Self.value(corner, gt, 20, 40) == 0)

        // Flip horizontal mirrors it.
        var flipped = CropSettings(); flipped.flipH = true
        let gf = Self.geometry(source: source, crop: flipped)
        #expect(abs(gf.map(StrokePoint(x: 0.1, y: 0.2)).x - 360) < 0.5)
        #expect(abs(gf.map(StrokePoint(x: 0.1, y: 0.2)).y - 40) < 0.5)

        // Brush size follows the short side of the source, scaled with the output.
        let half = DodgeBurnGeometry(crop: .identity, sourceSize: source, gradedSize: CGSize(width: 200, height: 100))
        #expect(abs(half.radius(size: 0.2) - 10) < 1e-9)
        #expect(abs(Self.geometry(source: source).radius(size: 0.2) - 20) < 1e-9)
    }

    @Test func straightenKeepsRoundBrushesRound() {
        var crop = CropSettings(); crop.straighten = 10
        let g = Self.geometry(source: CGSize(width: 400, height: 300), crop: crop)
        // The auto-fit scales the picture up, so the brush grows with it.
        #expect(g.radius(size: 0.2) > 0.2 * 300 / 2)
    }

    @Test func liveStrokeMatchesABatchRaster() throws {
        let g = Self.geometry(source: CGSize(width: 300, height: 200))
        let done = S.stroke(at: [(0.2, 0.3), (0.4, 0.3)], size: 0.1, strength: 0.7)
        var live = S.stroke(.burn, at: [(0.2, 0.7)], size: 0.12, strength: 0.8, flow: 0.4)
        let cache = DodgeBurnMaskCache()
        var last: [DodgeBurnLayer] = []
        for i in 1...12 {
            live.points.append(StrokePoint(x: 0.2 + 0.05 * Double(i), y: 0.7 - 0.02 * Double(i), pressure: 0.5 + 0.04 * Double(i)))
            last = cache.layers(for: [done, live], geometry: g)
        }
        #expect(cache.rebuilds == 0 && cache.incremental == 12)
        let reference = DodgeBurnRaster.rasterize([done, live], geometry: g)
        #expect(last.count == reference.order.count)
        Self.expectSame(try #require(cache.stateForTesting(geometry: g)), reference)
        // Commit it, then paint another: the cached committed state is reused.
        let again = S.stroke(at: [(0.8, 0.8)], size: 0.1)
        _ = cache.layers(for: [done, live, again], geometry: g)
        #expect(cache.rebuilds == 0)
        let ref3 = DodgeBurnRaster.rasterize([done, live, again], geometry: g)
        let cached = cache.layers(for: [done, live, again], geometry: g)
        #expect(cache.hits >= 1)
        #expect(cached.count == ref3.order.count)
        Self.expectSame(try #require(cache.stateForTesting(geometry: g)), ref3)
        // Editing an early stroke rebuilds from scratch and still matches.
        var edited = done; edited.strength = 0.3
        _ = cache.layers(for: [edited, live, again], geometry: g)
        #expect(cache.rebuilds == 1)
        Self.expectSame(try #require(cache.stateForTesting(geometry: g)),
                        DodgeBurnRaster.rasterize([edited, live, again], geometry: g))
    }

    static func expectSame(_ a: DodgeBurnState, _ b: DodgeBurnState) {
        #expect(a.order == b.order)
        for key in b.order {
            let x = a.buffers[key]!.values, y = b.buffers[key]!.values
            #expect(x.count == y.count)
            var worst: Float = 0
            for i in 0..<x.count { worst = max(worst, abs(x[i] - y[i])) }
            #expect(worst < 1e-5, "worst difference \(worst)")
        }
    }

    @Test func incrementalValuesEqualBatchValues() throws {
        let g = Self.geometry(source: CGSize(width: 300, height: 200))
        var stroke = S.stroke(at: [(0.1, 0.1)], size: 0.15, flow: 0.5)
        var live = DodgeBurnCoverage(bounds: DodgeBurnRect(x0: 0, y0: 0, x1: g.width, y1: g.height),
                                     radius: g.radius(size: stroke.size), feather: stroke.feather, flow: stroke.flow)
        live.feed(g.map(stroke.points[0]), pressure: 1)
        for i in 1...20 {
            let p = StrokePoint(x: 0.1 + 0.04 * Double(i), y: 0.1 + 0.03 * Double(i))
            stroke.points.append(p)
            live.feed(g.map(p), pressure: 1)
        }
        let batch = DodgeBurnRaster.coverage(of: stroke, geometry: g,
                                             bounds: DodgeBurnRect(x0: 0, y0: 0, x1: g.width, y1: g.height))
        #expect(batch.values == live.values)
    }

    @Test func regionMaskMatchesTheSameAreaOfTheWholeMask() {
        let source = CGSize(width: 300, height: 200)
        let whole = Self.geometry(source: source)
        let region = DodgeBurnGeometry(crop: .identity, sourceSize: source, gradedSize: source,
                                       region: CGRect(x: 100, y: 50, width: 120, height: 80))
        let stroke = S.stroke(at: [(0.45, 0.5), (0.6, 0.45)], size: 0.2, feather: 0.4)
        let a = DodgeBurnRaster.rasterize([stroke], geometry: whole)
        let b = DodgeBurnRaster.rasterize([stroke], geometry: region)
        let wa = a.buffers[a.order[0]]!.values, wb = b.buffers[b.order[0]]!.values
        for y in 0..<region.height {
            for x in 0..<region.width {
                // Region row 0 is CI y = 130; whole row for that is 200 - 130 = 70.
                #expect(abs(wb[y * region.width + x] - wa[(y + 70) * whole.width + x + 100]) < 1e-5)
            }
        }
    }
}

@Suite struct DodgeBurnRenderTests {
    typealias S = DodgeBurnModelTests
    let context = Renderer.sharedContext

    func renderer() throws -> Renderer { Renderer(library: try emptyLibrary()) }

    func recipe(_ strokes: DodgeBurnStroke...) -> Recipe {
        Recipe(dodgeBurn: DodgeBurnSettings(strokes: strokes))
    }

    /// Mean sRGB luma of a square of pixels around (x, y from the top).
    func luma(_ p: Pixels, _ x: Int, _ y: Int, r: Int = 2) -> Double {
        var sum = 0.0, n = 0.0
        let l = p.luma
        for yy in (y - r)...(y + r) { for xx in (x - r)...(x + r) { sum += l[yy * p.width + xx]; n += 1 } }
        return sum / n
    }

    @Test func dodgeBrightensUnderTheStrokeOnly() throws {
        let r = try renderer()
        let input = Fixture.solid(gray: 0.4, size: 200)
        let base = Pixels(r.apply(.neutral, to: input), context: context)
        let out = Pixels(r.apply(recipe(S.stroke(.dodge, at: [(0.5, 0.5)], size: 0.2, strength: 1, flow: 1, feather: 0.2)), to: input),
                         context: context)
        #expect(luma(out, 100, 100) > luma(base, 100, 100) + 0.1)
        // Far from the brush the pixels are exactly the original.
        for (x, y) in [(10, 10), (190, 190), (10, 190), (150, 100), (100, 160)] {
            let i = (y * 200 + x) * 4
            #expect(Array(out.rgba[i..<i + 4]) == Array(base.rgba[i..<i + 4]))
        }
    }

    @Test func burnDarkensAndKeepsHue() throws {
        let r = try renderer()
        let input = Fixture.solid(gray: 0.5, size: 200)
        let base = Pixels(r.apply(.neutral, to: input), context: context)
        let out = Pixels(r.apply(recipe(S.stroke(.burn, at: [(0.5, 0.5)], size: 0.2, strength: 1, flow: 1, feather: 0)), to: input),
                         context: context)
        #expect(luma(out, 100, 100) < luma(base, 100, 100) - 0.1)
        // A coloured pixel keeps its channel ratios when burned.
        let warm = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.3, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let w0 = Pixels(r.apply(.neutral, to: warm), context: context)
        let w1 = Pixels(r.apply(recipe(S.stroke(.burn, at: [(0.5, 0.5)], size: 0.2, strength: 0.6, feather: 0)), to: warm),
                        context: context)
        let i = (100 * 200 + 100) * 4
        #expect(w1.rgba[i] < w0.rgba[i])
        let ratio0 = Double(w0.rgba[i + 2]) / Double(w0.rgba[i]), ratio1 = Double(w1.rgba[i + 2]) / Double(w1.rgba[i])
        #expect(abs(ratio0 - ratio1) < 0.06, "\(ratio0) vs \(ratio1)")
    }

    @Test func rangeLimitsWhereItActs() throws {
        let r = try renderer()
        let dark = Fixture.solid(gray: 0.1, size: 100), light = Fixture.solid(gray: 0.9, size: 100)
        func lift(_ range: DodgeBurnRange, on image: CIImage) throws -> Double {
            var s = S.stroke(.dodge, at: [(0.5, 0.5)], size: 0.5, strength: 1, flow: 1, feather: 0)
            s.range = range
            let before = Pixels(r.apply(.neutral, to: image), context: context)
            let after = Pixels(r.apply(recipe(s), to: image), context: context)
            return luma(after, 50, 50) - luma(before, 50, 50)
        }
        #expect(try lift(.shadows, on: dark) > 0.05)
        #expect(try lift(.shadows, on: light) < 0.005)
        #expect(try lift(.highlights, on: light) > 0.01)
        #expect(try lift(.highlights, on: dark) < 0.005)
    }

    @Test func luminosityRangeLimitsTheStroke() throws {
        let r = try renderer()
        let mid = Fixture.solid(gray: 0.5, size: 100)
        var s = S.stroke(.dodge, at: [(0.5, 0.5)], size: 0.5, strength: 1, flow: 1, feather: 0)
        let free = Pixels(r.apply(recipe(s), to: mid), context: context)
        s.lumaRange = LumaRange(low: 0.8, high: 1, softness: 0)
        let limited = Pixels(r.apply(recipe(s), to: mid), context: context)
        let base = Pixels(r.apply(.neutral, to: mid), context: context)
        #expect(luma(free, 50, 50) > luma(base, 50, 50) + 0.05)
        // Outside the band nothing changes (up to one level of half-float rounding in the longer graph).
        #expect(zip(limited.rgba, base.rgba).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test func protectTonesStopsClippingAndCrushing() throws {
        let r = try renderer()
        let bright = Fixture.solid(gray: 0.8, size: 100), shade = Fixture.solid(gray: 0.12, size: 100)
        func red(_ mode: DodgeBurnMode, protect: Bool, on image: CIImage, range: DodgeBurnRange) -> Pixels {
            var s = S.stroke(mode, at: [(0.5, 0.5)], size: 0.6, strength: 1, flow: 1, feather: 0)
            s.protectTones = protect; s.range = range
            return Pixels(r.apply(recipe(s), to: image), context: context)
        }
        let before = Pixels(r.apply(.neutral, to: bright), context: context)
        let clipped = red(.dodge, protect: false, on: bright, range: .highlights)
        let kept = red(.dodge, protect: true, on: bright, range: .highlights)
        let i = (50 * 100 + 50) * 4
        #expect(clipped.rgba[i] >= 254)
        #expect(kept.rgba[i] < 254 && kept.rgba[i] > before.rgba[i])
        let crushed = red(.burn, protect: false, on: shade, range: .shadows)
        let safe = red(.burn, protect: true, on: shade, range: .shadows)
        #expect(safe.rgba[i] >= crushed.rgba[i])
        #expect(safe.rgba[i] > 0)
    }

    @Test func neutralOutputIsBitIdentical() throws {
        let r = try renderer()
        let input = Fixture.gradientAndPatches(size: 128)
        let base = Pixels(r.apply(.neutral, to: input), context: context).rgba
        var hidden = S.stroke(.dodge, size: 0.3); hidden.hidden = true
        var zero = S.stroke(.burn, size: 0.3, strength: 0)
        zero.strength = 0
        let eraseOnly = S.stroke(.erase, size: 0.3)
        for recipe in [Recipe(dodgeBurn: DodgeBurnSettings(strokes: [hidden])),
                       Recipe(dodgeBurn: DodgeBurnSettings(strokes: [zero])),
                       Recipe(dodgeBurn: DodgeBurnSettings(strokes: [eraseOnly]))] {
            #expect(Pixels(r.apply(recipe, to: input), context: context).rgba == base)
        }
        // A fully erased stroke is also a no-op.
        let painted = S.stroke(.dodge, size: 0.3, strength: 1)
        let erased = Recipe(dodgeBurn: DodgeBurnSettings(strokes: [painted, S.stroke(.erase, size: 0.5)]))
        #expect(Pixels(r.apply(erased, to: input), context: context).rgba == base)
    }

    @Test func strokeFollowsTheCropAndRotation() throws {
        let r = try renderer()
        // 400 x 200 source with a stroke on the right half's centre.
        let input = Fixture.solid(gray: 0.4, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        var recipe = recipe(S.stroke(.dodge, at: [(0.75, 0.5)], size: 0.3, strength: 1, flow: 1, feather: 0))
        recipe.crop.rect = CropRect(x: 0.5, y: 0, w: 0.5, h: 1)
        let cropped = Pixels(r.apply(recipe, to: input), context: context)
        let base = Pixels(r.apply(Recipe(crop: recipe.crop), to: input), context: context)
        #expect(cropped.width == 200 && cropped.height == 200)
        #expect(luma(cropped, 100, 100) > luma(base, 100, 100) + 0.05)
        #expect(luma(cropped, 10, 10) == luma(base, 10, 10))
        recipe.crop = CropSettings(rotate90: 1)
        let turned = Pixels(r.apply(recipe, to: input), context: context)
        let turnedBase = Pixels(r.apply(Recipe(crop: recipe.crop), to: input), context: context)
        // Rotated clockwise, the right-hand stroke ends up in the lower half, horizontally centred.
        #expect(turned.width == 200 && turned.height == 400)
        #expect(luma(turned, 100, 300) > luma(turnedBase, 100, 300) + 0.05)
        #expect(luma(turned, 100, 100) == luma(turnedBase, 100, 100))
    }

    @Test func previewAndFullResolutionAgree() throws {
        let r = try renderer()
        let big = Fixture.gradientAndPatches(size: 800)
        let stroke = S.stroke(.dodge, at: [(0.3, 0.7), (0.7, 0.6)], size: 0.2, strength: 0.8, flow: 0.6, feather: 0.5)
        let recipe = recipe(stroke)
        let full = r.apply(recipe, to: big)
        let small = r.apply(recipe, to: r.previewImage(from: big, maxPixelSize: 200))
        let scaledDown = r.previewImage(from: full, maxPixelSize: 200)
        let a = Pixels(scaledDown, context: context), b = Pixels(small, context: context)
        #expect(a.width == b.width)
        let la = a.luma, lb = b.luma
        let diff = zip(la, lb).map { abs($0 - $1) }
        #expect(mean(diff) < 0.02, "mean luma difference \(mean(diff))")
    }

    @Test func engineFramesChangeUnderTheStroke() throws {
        let engine = PreviewEngine(renderer: try renderer(), context: context)
        engine.setSource(Fixture.solid(gray: 0.4, size: 600).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400)))
        let canvas = CGSize(width: 300, height: 300)
        let plain = try #require(engine.render(.neutral, canvas: canvas))
        let painted = try #require(engine.render(recipe(S.stroke(.dodge, at: [(0.5, 0.5)], size: 0.3, strength: 1, flow: 1)),
                                                 canvas: canvas))
        func px(_ f: PreviewFrame, _ x: Int, _ y: Int) -> Double {
            let cg = f.cgImage(context: context)!
            let p = Pixels(CIImage(cgImage: cg), context: context)
            return luma(p, x, y)
        }
        #expect(plain.pixelSize == painted.pixelSize)
        let w = Int(plain.pixelSize.width), h = Int(plain.pixelSize.height)
        #expect(px(painted, w / 2, h / 2) > px(plain, w / 2, h / 2) + 0.05)
        #expect(px(painted, 5, 5) == px(plain, 5, 5))
        // Zoomed frames follow the same strokes.
        let zoomed = try #require(engine.renderZoomed(recipe(S.stroke(.dodge, at: [(0.5, 0.5)], size: 0.3, strength: 1, flow: 1)),
                                                      region: ZoomRegion(scale: 1, rect: CGRect(x: 200, y: 100, width: 200, height: 200))))
        let zbase = try #require(engine.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 200, y: 100, width: 200, height: 200))))
        #expect(px(zoomed, 100, 100) > px(zbase, 100, 100) + 0.05)
    }
}
