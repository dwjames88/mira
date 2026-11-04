import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct FilmPhase2Tests {
    let context = Renderer.sharedContext

    static func library() throws -> FilmLibrary {
        try SyntheticFilms.library([
            .init(id: "neg", family: .colorNegative),
            .init(id: "slide", family: .slide),
            .init(id: "bw", family: .blackAndWhite),
        ])
    }

    /// Horizontal gradient between two sRGB-encoded grays, as linear light.
    static func gradient(_ lo: Double, _ hi: Double, width: Int = 256, height: Int = 64) -> CIImage {
        PipelineFixture.linearImage(width: width, height: height) { x, _ in
            let e = lo + (hi - lo) * Double(x) / Double(width - 1)
            let l = Float(e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4))
            return (l, l, l)
        }
    }

    // MARK: Push / pull

    @Test func pushRaisesGrainAndContrastMonotonically() throws {
        let r = Renderer(library: try Self.library())
        let flat = PipelineFixture.flat(0.4, width: 800, height: 800)
        let ramp = Self.gradient(0.25, 0.5)
        var grains: [Double] = [], contrasts: [Double] = []
        for push in [-1.0, 0, 1, 2] {
            // Grain measured on a patch, contrast on the grain-free ramp; exposure is compensated
            // out of the picture by measuring spread only.
            let g = Pixels(r.apply(Recipe(filmID: "neg", grainAmount: 0.6, push: push), to: flat), context: context)
            grains.append(stddev(g.channel(1)))
            let c = Pixels(r.apply(Recipe(filmID: "neg", push: push), to: ramp), context: context)
            contrasts.append(stddev(c.luma))
        }
        for i in 1..<grains.count { #expect(grains[i] > grains[i - 1], "grain \(grains)") }
        for i in 1..<contrasts.count { #expect(contrasts[i] > contrasts[i - 1], "contrast \(contrasts)") }
    }

    @Test func pushedSlideClipsMore() throws {
        let r = Renderer(library: try Self.library())
        let ramp = PipelineFixture.linearImage(width: 256, height: 1) { x, _ in
            let v = Float(x) / 255
            return (v, v, v)
        }
        func clipped(_ push: Double) -> Int {
            let out = LinearPixels(r.apply(Recipe(filmID: "slide", exposure: 0.5, push: push), to: ramp))
            return (0..<256).filter { out.value($0, 0, 1) >= 0.999 }.count
        }
        #expect(clipped(2) > clipped(0) + 10, "\(clipped(0)) vs \(clipped(2))")
    }

    @Test func pushLiftsNegativeBlacksOnly() throws {
        let r = Renderer(library: try Self.library())
        let black = PipelineFixture.flat(0.0, width: 16, height: 16)
        let neg = Pixels(r.apply(Recipe(filmID: "neg", push: 2), to: black), context: context)
        let slide = Pixels(r.apply(Recipe(filmID: "slide", push: 2), to: black), context: context)
        #expect(mean(neg.channel(1)) > 0.015)
        #expect(mean(slide.channel(1)) < 0.005)
    }

    // MARK: Scan

    @Test func neutralScanIsIdentityAndProfilesDiffer() throws {
        let r = Renderer(library: try Self.library())
        let input = Fixture.gradientAndPatches(size: 128)
        let legacy = Pixels(r.apply(Recipe(filmID: "neg", pipeline: Recipe.legacyPipeline), to: input), context: context)
        let neutral = Pixels(r.apply(Recipe(filmID: "neg", scanProfile: .neutral), to: input), context: context)
        #expect(legacy.rgba == neutral.rgba)

        let gray = PipelineFixture.flat(0.5, width: 16, height: 16)
        func cast(_ p: ScanProfile) -> Double {
            let o = Pixels(r.apply(Recipe(filmID: "neg", scanProfile: p), to: gray), context: context)
            return mean(o.channel(2)) - mean(o.channel(0))
        }
        #expect(cast(.frontier) > cast(.neutral) + 0.01)
        #expect(cast(.noritsu) < cast(.neutral) - 0.01)
        #expect(cast(.frontier) > cast(.noritsu) + 0.03)

        let ramp = Self.gradient(0.1, 0.9)
        func spread(_ p: ScanProfile) -> Double {
            stddev(Pixels(r.apply(Recipe(filmID: "neg", scanProfile: p), to: ramp), context: context).luma)
        }
        #expect(spread(.frontier) > spread(.noritsu))
    }

    // MARK: Toning

    @Test func toningAppliesOnlyToMonochromeAndKeepsLuma() throws {
        let r = Renderer(library: try Self.library())
        let gray = PipelineFixture.flat(0.5, width: 32, height: 32)
        let plain = Pixels(r.apply(Recipe(filmID: "bw"), to: gray), context: context)
        for toning in [Toning.selenium, .sepia, .cyanotype, .copper] {
            let o = Pixels(r.apply(Recipe(filmID: "bw", toning: toning, toningStrength: 1), to: gray), context: context)
            #expect(abs(mean(o.luma) - mean(plain.luma)) / mean(plain.luma) < 0.02, "\(toning)")
            #expect(abs(mean(o.channel(0)) - mean(o.channel(2))) > 0.01 || toning == .selenium, "\(toning) not visible")
        }
        let sepia = Pixels(r.apply(Recipe(filmID: "bw", toning: .sepia, toningStrength: 1), to: gray), context: context)
        #expect(mean(sepia.channel(0)) > mean(sepia.channel(2)) + 0.02)
        let cyan = Pixels(r.apply(Recipe(filmID: "bw", toning: .cyanotype, toningStrength: 1), to: gray), context: context)
        #expect(mean(cyan.channel(2)) > mean(cyan.channel(0)) + 0.02)

        let colourPlain = Pixels(r.apply(Recipe(filmID: "neg"), to: gray), context: context)
        let colourToned = Pixels(r.apply(Recipe(filmID: "neg", toning: .sepia, toningStrength: 1), to: gray), context: context)
        #expect(colourPlain.rgba == colourToned.rgba)
        let zero = Pixels(r.apply(Recipe(filmID: "bw", toning: .sepia, toningStrength: 0), to: gray), context: context)
        #expect(zero.rgba == plain.rgba)
    }

    // MARK: Latitude meter

    @Test func latitudeMeterReadsFractionsOutsideTheRange() throws {
        let r = Renderer(library: try Self.library())
        func frame(stops: Float) -> CIImage {
            let v = 0.18 * exp2(stops)
            return PipelineFixture.linearImage(width: 200, height: 100) { x, _ in
                x < 100 ? (v, v, v) : (0.18, 0.18, 0.18)
            }
        }
        let slideRecipe = Recipe(filmID: "slide"), negRecipe = Recipe(filmID: "neg")
        let hot = frame(stops: 4)
        let slide4 = try #require(r.latitudeReading(slideRecipe, input: hot, context: context))
        let neg4 = try #require(r.latitudeReading(negRecipe, input: hot, context: context))
        #expect(abs(slide4.over - 0.5) < 0.05 && abs(neg4.over - 0.5) < 0.05, "\(slide4) \(neg4)")
        #expect(slide4.overStops > 0 && slide4.under == 0)
        let warm = frame(stops: 2)
        let slide2 = try #require(r.latitudeReading(slideRecipe, input: warm, context: context))
        let neg2 = try #require(r.latitudeReading(negRecipe, input: warm, context: context))
        #expect(abs(slide2.over - 0.5) < 0.05, "\(slide2)")
        #expect(neg2.over < 0.02 && neg2.overStops == 0, "\(neg2)")
        // Exposure and push move the frame through the range.
        let pushed = try #require(r.latitudeReading(Recipe(filmID: "neg", exposure: 2), input: warm, context: context))
        #expect(pushed.over > 0.4)
        #expect(r.latitudeReading(Recipe(), input: hot, context: context) == nil)
    }
}
