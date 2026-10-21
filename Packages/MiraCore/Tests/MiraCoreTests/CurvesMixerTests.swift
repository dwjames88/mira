import CoreImage
import Foundation
import Testing
@testable import MiraCore

private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 16) -> CIImage {
    let c = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    return CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}

/// HSL hue in degrees of an 8-bit sRGB pixel.
private func hslHue(_ r: Double, _ g: Double, _ b: Double) -> Double {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    guard d > 0 else { return 0 }
    var h: Double
    if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
    else if mx == g { h = (b - r) / d + 2 }
    else { h = (r - g) / d + 4 }
    h *= 60
    return h < 0 ? h + 360 : h
}

@Suite struct CurvesTests {
    let context = Renderer.sharedContext

    @Test func kernelsLoad() {
        #expect(GradeKernels.isAvailable)
    }

    @Test func identityDefaultGivesIdentityLUT() {
        let lut = CurvesSettings.identity.lut(.rgb)
        #expect(lut.count == 1024)
        for (i, v) in lut.enumerated() { #expect(abs(Double(v) - Double(i) / 1023) < 1e-6) }
        #expect(CurvesSettings.identity.isIdentity)
        #expect(Recipe.neutral.curves.isIdentity)
    }

    @Test func monotoneInterpolationNeverOvershoots() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let n = Int.random(in: 2...8, using: &rng)
            let xs = ([0.0, 1.0] + (0..<(n - 2)).map { _ in Double.random(in: 0.02...0.98, using: &rng) }).sorted()
            let ys = (0..<n).map { _ in Double.random(in: 0...1, using: &rng) }.sorted()
            let pts = zip(xs, ys).map { CurvePoint(x: $0, y: $1) }
            let curve = MonotoneCurve(pts)
            var previous = -1.0
            for i in 0...512 {
                let x = Double(i) / 512
                let v = curve.value(at: x)
                #expect(v >= previous - 1e-12)
                previous = v
                // Within the range of the two neighbouring points.
                let upper = pts.firstIndex { $0.x >= x } ?? pts.count - 1
                let lower = pts.lastIndex { $0.x <= x } ?? 0
                let lo = min(pts[lower].y, pts[upper].y), hi = max(pts[lower].y, pts[upper].y)
                #expect(v >= lo - 1e-9 && v <= hi + 1e-9)
            }
        }
    }

    @Test func nonMonotonePointsStayBetweenNeighbours() {
        let pts = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.4, y: 0.9), CurvePoint(x: 0.7, y: 0.3), CurvePoint(x: 1, y: 0.8)]
        let curve = MonotoneCurve(pts)
        for i in 0...400 {
            let x = Double(i) / 400
            let v = curve.value(at: x)
            let upper = pts.firstIndex { $0.x >= x } ?? 3, lower = pts.lastIndex { $0.x <= x } ?? 0
            #expect(v >= min(pts[lower].y, pts[upper].y) - 1e-9)
            #expect(v <= max(pts[lower].y, pts[upper].y) + 1e-9)
        }
    }

    @Test func pointsAreSortedAndPassedThrough() {
        let pts = [CurvePoint(x: 1, y: 1), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 0, y: 0)]
        let curve = MonotoneCurve(pts)
        #expect(abs(curve.value(at: 0.5) - 0.7) < 1e-12)
        #expect(curve.value(at: 0) == 0)
        #expect(curve.value(at: 1) == 1)
        let lut = CurvesSettings(rgb: pts).lut(.rgb)
        #expect(abs(Double(lut[0])) < 1e-6 && abs(Double(lut[1023]) - 1) < 1e-6)
    }

    @Test func identityCurvesRenderBitIdentical() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 128)
        var recipe = Recipe(exposure: 0.2, contrast: 0.1)
        let base = Pixels(r.apply(recipe, to: input), context: context).rgba
        recipe.curves = CurvesSettings(rgb: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)])
        #expect(Pixels(r.apply(recipe, to: input), context: context).rgba == base)
    }

    @Test func singleRGBPointBrightensMidGrey() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
        let out = Pixels(r.apply(recipe, to: Fixture.solid(gray: 0.5, size: 16)), context: context)
        for c in 0..<3 { #expect(abs(mean(out.channel(c)) - 0.7) < 0.01, "channel \(c): \(mean(out.channel(c)))") }
    }

    @Test func redChannelCurveOnlyMovesRed() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 1)]
        let out = Pixels(r.apply(recipe, to: Fixture.solid(gray: 0.5, size: 16)), context: context)
        #expect(abs(mean(out.channel(0)) - 0.3) < 0.01)
        #expect(abs(mean(out.channel(1)) - 0.5) < 0.01)
        #expect(abs(mean(out.channel(2)) - 0.5) < 0.01)
    }

    @Test func luminanceCurveKeepsHue() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.curves.luminance = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.35), CurvePoint(x: 1, y: 1)]
        let input = solid(0.6, 0.4, 0.3)
        let before = Pixels(input, context: context)
        let after = Pixels(r.apply(recipe, to: input), context: context)
        let b = (before.channel(0)[0], before.channel(1)[0], before.channel(2)[0])
        let a = (after.channel(0)[0], after.channel(1)[0], after.channel(2)[0])
        #expect(0.2126 * a.0 + 0.7152 * a.1 + 0.0722 * a.2 < 0.2126 * b.0 + 0.7152 * b.1 + 0.0722 * b.2 - 0.03)
        #expect(abs(hslHue(a.0, a.1, a.2) - hslHue(b.0, b.1, b.2)) < 2)
    }

    @Test func curveRecipeRoundTrips() throws {
        var recipe = Recipe(exposure: 0.1)
        recipe.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.55), CurvePoint(x: 1, y: 1)]
        recipe.curves.blue = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 0.95)]
        #expect(try Recipe.decode(recipe.encoded()) == recipe)
    }
}

@Suite struct ColorMixerTests {
    let context = Renderer.sharedContext

    @Test func identityIsBitIdentical() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 128)
        var recipe = Recipe(contrast: 0.1)
        let base = Pixels(r.apply(recipe, to: input), context: context).rgba
        recipe.colorMixer.red = ColorAdjust(hue: 0.5)
        recipe.colorMixer.red = .zero
        #expect(recipe.colorMixer.isIdentity)
        #expect(Pixels(r.apply(recipe, to: input), context: context).rgba == base)
    }

    @Test func redHuePlusMovesToOrange() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.colorMixer.red.hue = 1
        let out = Pixels(r.apply(recipe, to: solid(1, 0, 0)), context: context)
        let h = hslHue(mean(out.channel(0)), mean(out.channel(1)), mean(out.channel(2)))
        #expect(h > 15 && h < 35, "hue \(h)")
    }

    @Test func redHueMinusMovesToMagenta() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.colorMixer.red.hue = -1
        let out = Pixels(r.apply(recipe, to: solid(1, 0, 0)), context: context)
        let h = hslHue(mean(out.channel(0)), mean(out.channel(1)), mean(out.channel(2)))
        #expect(h > 310 && h < 355, "hue \(h)")
    }

    @Test func saturationMinusDesaturatesTheRange() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.colorMixer.green.saturation = -1
        let input = solid(0.2, 0.7, 0.3)
        let out = Pixels(r.apply(recipe, to: input), context: context)
        let spread = max(mean(out.channel(0)), mean(out.channel(1)), mean(out.channel(2)))
            - min(mean(out.channel(0)), mean(out.channel(1)), mean(out.channel(2)))
        #expect(spread < 0.08, "spread \(spread)")
    }

    @Test func luminancePlusBrightensWithoutClipping() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        recipe.colorMixer.blue.luminance = 1
        let input = solid(0.2, 0.3, 0.85)
        let before = Pixels(input, context: context), after = Pixels(r.apply(recipe, to: input), context: context)
        #expect(after.luma[0] > before.luma[0] + 0.05)
        #expect(after.channel(2)[0] <= 1)
    }

    @Test func neutralGreyIsUnchangedForAnySettings() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe.neutral
        for range in ColorRange.allCases {
            recipe.colorMixer[range] = ColorAdjust(hue: 1, saturation: 1, luminance: -1)
        }
        for g in [0.0, 0.1, 0.5, 0.9, 1.0] {
            let input = Fixture.solid(gray: CGFloat(g), size: 8)
            let a = Pixels(r.apply(recipe, to: input), context: context).rgba, b = Pixels(input, context: context).rgba
            // Within one 8-bit step (the kernel path rounds through half floats).
            #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "grey \(g)")
        }
    }

    @Test func rangeFromColor() {
        #expect(ColorRange.nearest(sRGB: 1, 0, 0) == .red)
        #expect(ColorRange.nearest(sRGB: 0, 1, 0) == .green)
        #expect(ColorRange.nearest(sRGB: 0, 0, 1) == .blue)
        #expect(ColorRange.nearest(sRGB: 1, 1, 0) == .yellow)
        #expect(ColorRange.nearest(sRGB: 0, 1, 1) == .aqua)
        #expect(ColorRange.nearest(sRGB: 1, 0, 1) == .magenta)
        #expect(ColorRange.nearest(sRGB: 1, 0.55, 0) == .orange)
        #expect(ColorRange.nearest(sRGB: 0.5, 0.5, 0.5) == nil)
        #expect(ColorRange.nearest(toHue: 5) == .magenta || ColorRange.nearest(toHue: 5) == .red)
    }

    @Test func mixerRecipeRoundTrips() throws {
        var recipe = Recipe.neutral
        recipe.colorMixer.orange = ColorAdjust(hue: 0.3, saturation: -0.2, luminance: 0.1)
        recipe.curves.green = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
        #expect(try Recipe.decode(recipe.encoded()) == recipe)
        let adjustment = try MiraAdjustment.encode(recipe)
        let back = MiraAdjustment.decode(formatIdentifier: MiraAdjustment.formatIdentifier,
                                         formatVersion: MiraAdjustment.formatVersion, data: adjustment)
        #expect(back == recipe)
    }

    @Test func oldRecipeJSONDecodesToIdentity() throws {
        let old = Data(#"{"exposure":0.4,"filmID":"x","crop":{},"version":1}"#.utf8)
        let r = try Recipe.decode(old)
        #expect(r.curves.isIdentity && r.colorMixer.isIdentity)
        #expect(r.exposure == 0.4)
    }

    @Test func identityRecipeEncodesWithoutNewKeys() throws {
        let json = String(decoding: try Recipe.neutral.encoded(), as: UTF8.self)
        #expect(!json.contains("curves") && !json.contains("colorMixer"))
    }
}
