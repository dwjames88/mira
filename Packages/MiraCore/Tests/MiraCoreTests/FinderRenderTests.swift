import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

/// The two live-viewfinder renderer additions (`withGrainSeed`, `withTextureScale`) and the finder-capture parity.
@Suite("Finder rendering", .serialized)
struct FinderRenderTests {
    /// Strong halation, bloom and grain on an identity LUT, so the texture stages are what the renders differ in.
    static func renderer() throws -> Renderer {
        let spec = SyntheticFilms.Spec(
            id: "tex", family: .colorNegative,
            character: .init(grainStrength: 1.6, halationStrength: 2.0, halationRadius: 0.03, bloom: 1.6))
        return Renderer(library: try SyntheticFilms.library([spec]))
    }

    static var recipe: Recipe { Recipe(filmID: "tex").applyingNativeTexture(filmID: "tex") }

    /// Mid grey with a bright square (a light source) and a flat patch for measuring grain.
    static func scene(width: Int = 512, height: Int = 384) -> CIImage {
        PipelineFixture.linearImage(width: width, height: height) { x, y in
            let inLight = abs(x - width / 4) < 12 && abs(y - height / 2) < 12
            let v: Float = inLight ? 6 : 0.18
            return (v, v, v)
        }
    }

    static let context = Renderer.makeContext()

    static func pixels(_ r: Renderer, _ recipe: Recipe, _ input: CIImage) -> LinearPixels {
        LinearPixels(r.apply(recipe, to: input), context: context)
    }

    /// Standard deviation of luma over a rectangle.
    static func rms(_ p: LinearPixels, x: Range<Int>, y: Range<Int>) -> Double {
        var v: [Double] = []
        for yy in y { for xx in x { v.append(p.luma(xx, yy)) } }
        return stddev(v)
    }

    static func meanRGB(_ p: LinearPixels) -> [Double] {
        (0..<3).map { c in
            var s = 0.0
            for i in 0..<(p.width * p.height) { s += Double(p.rgba[i * 4 + c]) }
            return s / Double(p.width * p.height)
        }
    }

    static func maxDiff(_ a: LinearPixels, _ b: LinearPixels) -> Double {
        zip(a.rgba, b.rgba).reduce(0.0) { max($0, Double(abs($1.0 - $1.1))) }
    }

    /// Summed luma that halation adds in a box around the light, away from its edge.
    static func halationEnergy(_ r: Renderer, _ input: CIImage) -> Double {
        var on = recipe, off = recipe
        on.grainAmount = 0; off.grainAmount = 0; on.bloomAmount = 0; off.bloomAmount = 0
        off.halationAmount = 0
        let a = pixels(r, on, input), b = pixels(r, off, input)
        var sum = 0.0
        for y in 0..<a.height { for x in 0..<a.width { sum += a.luma(x, y) - b.luma(x, y) } }
        return sum
    }

    // MARK: Grain seed

    @Test func nilSeedOverrideIsTodaysOutput() throws {
        let r = try Self.renderer(), input = Self.scene()
        let a = Self.pixels(r, Self.recipe, input)
        let b = Self.pixels(r.withGrainSeed(nil), Self.recipe, input)
        #expect(Self.maxDiff(a, b) == 0)
    }

    @Test func seedOverrideChangesThePatternNotTheStrength() throws {
        let r = try Self.renderer(), input = Self.scene()
        var recipe = Self.recipe
        recipe.halationAmount = 0; recipe.bloomAmount = 0
        let base = Self.pixels(r, recipe, input)
        let one = Self.pixels(r.withGrainSeed(12345), recipe, input)
        let two = Self.pixels(r.withGrainSeed(12346), recipe, input)
        #expect(Self.maxDiff(base, one) > 0.01)
        #expect(Self.maxDiff(one, two) > 0.01)
        let region = 200..<320, rows = 40..<140
        let rBase = Self.rms(base, x: region, y: rows), rOne = Self.rms(one, x: region, y: rows), rTwo = Self.rms(two, x: region, y: rows)
        #expect(rBase > 0.002, "grain should be visible: \(rBase)")
        #expect(abs(rOne / rBase - 1) < 0.15 && abs(rTwo / rBase - 1) < 0.15, "rms \(rBase) \(rOne) \(rTwo)")
        // The same override is deterministic.
        #expect(Self.maxDiff(one, Self.pixels(r.withGrainSeed(12345), recipe, input)) == 0)
    }

    @Test func seedsStayExactInAFloat() {
        #expect(Renderer.exactSeed(12345) == 12345)
        #expect(Renderer.exactSeed(16_777_216 + 5) == 5)
        #expect(Renderer.exactSeed(-1) == 16_777_215)
        #expect(Renderer.exactSeed(.nan) == 0 && Renderer.exactSeed(.infinity) == 0)
        #expect(Renderer.exactSeed(1e18) < 16_777_216)
        for v in [0.0, 1.0, 9_999_999.0, 16_777_215.0] { #expect(Double(Float(Renderer.exactSeed(v))) == Renderer.exactSeed(v)) }
    }

    @Test func overridesAreNotPartOfTheRecipe() throws {
        let r = try Self.renderer()
        let a = try JSONEncoder().encode(Self.recipe)
        _ = r.withGrainSeed(7).withTextureScale(0.5)
        let json = String(decoding: a, as: UTF8.self).lowercased()
        #expect(!json.contains("seed") && !json.contains("texturescale"))
        #expect(r.grainSeedOverride == nil && r.textureScale == 1)
    }

    // MARK: Texture scale

    @Test func textureScaleClamps() throws {
        let r = try Self.renderer()
        #expect(r.withTextureScale(0.1).textureScale == 0.25)
        #expect(r.withTextureScale(2).textureScale == 1)
        #expect(r.withTextureScale(.nan).textureScale == 1)
    }

    @Test func textureScaleOneIsTodaysOutput() throws {
        let r = try Self.renderer(), input = Self.scene()
        #expect(Self.maxDiff(Self.pixels(r, Self.recipe, input), Self.pixels(r.withTextureScale(1), Self.recipe, input)) == 0)
    }

    @Test(arguments: [(512, 384), (1280, 960)])
    func halfTextureScaleKeepsColourHalationAndGrain(size: (Int, Int)) throws {
        let r = try Self.renderer(), input = Self.scene(width: size.0, height: size.1)
        let patch = (size.0 * 5 / 12)..<(size.0 * 5 / 8), rows = (size.1 / 10)..<(size.1 * 3 / 8)
        let half = r.withTextureScale(0.5)
        let full = Self.pixels(r, Self.recipe, input), reduced = Self.pixels(half, Self.recipe, input)
        #expect(reduced.width == full.width && reduced.height == full.height)
        #expect(reduced.rgba.allSatisfy { $0.isFinite })

        let mf = Self.meanRGB(full), mr = Self.meanRGB(reduced)
        for c in 0..<3 { #expect(abs(mr[c] / mf[c] - 1) < 0.01, "mean \(c): \(mf[c]) vs \(mr[c])") }

        let ef = Self.halationEnergy(r, input), er = Self.halationEnergy(half, input)
        #expect(ef > 1, "halation energy \(ef)")
        #expect(abs(er / ef - 1) < 0.04, "halation energy full \(ef) half \(er)")

        let gf = Self.rms(full, x: patch, y: rows), gr = Self.rms(reduced, x: patch, y: rows)
        #expect(abs(gr / gf - 1) < 0.08, "grain rms full \(gf) half \(gr)")
    }

    @Test func reducedTextureStagesAreNaNSafe() throws {
        let r = try Self.renderer().withTextureScale(0.5)
        let input = PipelineFixture.linearImage(width: 128, height: 96) { x, y in
            x == 40 && y == 40 ? (.nan, .infinity, -.infinity) : (0.4, 0.4, 0.4)
        }
        #expect(Self.pixels(r, Self.recipe, input).rgba.allSatisfy { $0.isFinite })
    }

    @Test func legacyPipelineTextureScaleOneIsUnchangedAndHalfIsClose() throws {
        let r = try Self.renderer(), input = Self.scene()
        var recipe = Recipe(filmID: nil, grainAmount: 0.3, halationAmount: 0.6, halationRadius: 0.5, bloomAmount: 0.5)
        recipe.pipeline = 1
        let full = Self.pixels(r, recipe, input)
        #expect(Self.maxDiff(full, Self.pixels(r.withTextureScale(1), recipe, input)) == 0)
        let half = Self.pixels(r.withTextureScale(0.5), recipe, input)
        let mf = Self.meanRGB(full), mh = Self.meanRGB(half)
        for c in 0..<3 { #expect(abs(mh[c] / mf[c] - 1) < 0.03, "legacy mean \(c): \(mf[c]) vs \(mh[c])") }
    }

    // MARK: Finder and capture parity (plan 4.6)

    static func sampleURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures/sample.jpg")
    }

    @Test func finderRenderMatchesCaptureRender() throws {
        let r = try Self.renderer()
        let url = Self.sampleURL()
        guard let loaded = ImageSource.load(url: url) else { print("SKIPPED: \(url.path) not present"); return }
        // A full-size frame of about 1200 px on the long side, and the finder's half-size copy of it.
        let longSide = max(loaded.extent.width, loaded.extent.height)
        let fullFactor = min(1, 1200 / longSide)
        let full = Self.resized(loaded, by: fullFactor)
        let finder = Self.resized(full, by: 0.5)
        let recipe = Self.recipe
        let capture = r.apply(recipe, to: full)
        let live = r.withPreviewScale(0.5).apply(recipe, to: finder)
        let captureDown = Self.resized(capture, by: 0.5)
        let a = LinearPixels(captureDown, context: Self.context), b = LinearPixels(live, context: Self.context)
        #expect(a.width == b.width && a.height == b.height)
        let ma = Self.meanRGB(a), mb = Self.meanRGB(b)
        for c in 0..<3 { #expect(abs(mb[c] / ma[c] - 1) < 0.01, "parity mean \(c): \(ma[c]) vs \(mb[c])") }
        // Colour: the ratio of channel means (what the eye reads as the cast) agrees.
        #expect(abs((mb[0] / mb[2]) / (ma[0] / ma[2]) - 1) < 0.01)
        // Grain: noise in a flat patch of the render minus the same patch without grain.
        var plain = recipe; plain.grainAmount = 0
        let plainFull = LinearPixels(Self.resized(r.apply(plain, to: full), by: 0.5), context: Self.context)
        let plainLive = LinearPixels(r.withPreviewScale(0.5).apply(plain, to: finder), context: Self.context)
        func noise(_ g: LinearPixels, _ p: LinearPixels) -> Double {
            var d: [Double] = []
            for i in 0..<(g.width * g.height) { d.append(Double(g.rgba[i * 4 + 1] - p.rgba[i * 4 + 1])) }
            return stddev(d)
        }
        let na = noise(a, plainFull), nb = noise(b, plainLive)
        #expect(na > 0 && nb > 0)
        // Measured finder / capture-downscaled ratio: 0.58. The finder is the grain model at its own coarser pitch (bigger
        // pixel aperture, so quieter) while the downscaled capture keeps the full-size field's fine grain averaged;
        // the band is 0.4...1.5 and a regression in the previewScale math (ratio near 0 or >> 1) still trips it.
        #expect(nb / na > 0.4 && nb / na < 1.5, "parity grain rms capture-downscaled \(na) finder \(nb)")
    }

    static func resized(_ image: CIImage, by factor: CGFloat) -> CIImage {
        guard factor < 1 else { return image }
        let out = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor), highQualityDownsample: true)
        let e = out.extent
        let size = CGRect(x: 0, y: 0, width: e.width.rounded(), height: e.height.rounded())
        return out.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).cropped(to: size)
    }
}
