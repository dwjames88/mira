import CoreImage
import Foundation
import Testing
@testable import MiraCore

/// Recipes with `pipeline == 1` must keep rendering exactly as they did before the film-science
/// pipeline existed. The expected numbers (channel means, luma spread and an FNV-1a hash of the
/// 8-bit pixels) were captured from the renderer before pipeline 2 was added. If the hash alone
/// differs on other GPU hardware, the statistics still guard the look.
@Suite struct LegacyPipelineTests {
    struct Case {
        var name: String
        var recipe: Recipe
        /// mean r, g, b and luma standard deviation
        var stats: [Double]
        var hash: UInt64
    }

    static let L = Recipe.legacyPipeline

    static let cases: [Case] = [
        Case(name: "synthetic film + grain + halation",
             recipe: Recipe(filmID: "square", grainAmount: 0.5, halationAmount: 0.6, pipeline: L),
             stats: [0.38671013327209425, 0.3423481062347654, 0.31016211416218, 0.27287467314119884],
             hash: 9719297569746610027),
        Case(name: "invert + exposure + contrast + warmth + tint",
             recipe: Recipe(filmID: "invert", strength: 0.7, exposure: 0.6, contrast: 0.3, warmth: 0.5, tint: -0.2, pipeline: L),
             stats: [0.6158930759804803, 0.5911075367645588, 0.5604473039214708, 0.09830196474049502],
             hash: 7018058250290257445),
        Case(name: "no film: exposure, saturation, grain, bloom, vignette",
             recipe: Recipe(exposure: -0.4, saturation: 0.2, grainAmount: 0.7, grainSize: 0.8, bloomAmount: 0.4, vignetteAmount: 0.5, pipeline: L),
             stats: [0.4166623583027229, 0.39108060948994466, 0.36145396513106165, 0.19106028800395977],
             hash: 8045052086289440048),
        Case(name: "warmth over a non-linear LUT",
             recipe: Recipe(filmID: "square", warmth: 0.8, pipeline: L),
             stats: [0.4076363357845166, 0.3359834558824335, 0.2696920955884152, 0.2729786753160541],
             hash: 5977125631612558629),
        Case(name: "bundled kodak-portra-400 with everything",
             recipe: Recipe(filmID: "kodak-portra-400", exposure: 0.3, contrast: 0.2, warmth: 0.3, grainAmount: 0.5,
                            halationAmount: 0.5, halationRadius: 0.7, pipeline: L),
             stats: [0.6757183598537008, 0.6238438026577436, 0.5607067033356649, 0.2978134832883525],
             // kodak-portra-400 ships as an exact 64^3 cube, so this is the original hash.
             hash: 12106836713621142157),
    ]

    static func render(_ recipe: Recipe, renderer: Renderer) -> Pixels {
        Pixels(renderer.apply(recipe, to: Fixture.gradientAndPatches(size: 256)), context: Renderer.makeContext())
    }

    static func fnv(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    @Test func legacyRecipesRenderAsBefore() throws {
        let synthetic = try SyntheticFilms.library([
            .init(id: "square", family: .colorNegative, cube: .square),
            .init(id: "invert", family: .blackAndWhite, cube: .invert),
        ])
        let bundled = try? FilmLibrary(directory: FilmTests.filmsDirectory())
        for c in Self.cases {
            let lib = c.recipe.filmID == "kodak-portra-400" ? bundled : synthetic
            guard let lib, c.recipe.filmID == nil || lib.film(id: c.recipe.filmID!) != nil else {
                print("SKIPPED \(c.name): film missing"); continue
            }
            let px = Self.render(c.recipe, renderer: Renderer(library: lib))
            let got = [mean(px.channel(0)), mean(px.channel(1)), mean(px.channel(2)), stddev(px.luma)]
            for (g, e) in zip(got, c.stats) { #expect(abs(g - e) < 5e-4, "\(c.name): \(got) vs \(c.stats)") }
            #expect(Self.fnv(px.rgba) == c.hash, "\(c.name): pixel hash changed (\(Self.fnv(px.rgba)))")
        }
    }
}
