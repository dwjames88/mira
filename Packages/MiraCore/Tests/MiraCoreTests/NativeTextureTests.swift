import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite("Native texture levels and bloom character")
struct NativeTextureTests {
    @Test func filmSetsTextureToNativeAndOriginalToZero() {
        var r = Recipe(filmID: "a", grainAmount: 0.9, grainSize: 0.1, halationAmount: 0.2, halationRadius: 0.8, bloomAmount: 0.7)
        r.contrast = 0.3
        let film = r.applyingNativeTexture(filmID: "b")
        #expect(film.grainAmount == 0.5 && film.halationAmount == 0.5 && film.bloomAmount == 0.5)
        #expect(film.grainSize == 0.5 && film.halationRadius == 0.5)
        #expect(film.contrast == 0.3)
        let original = r.applyingNativeTexture(filmID: nil)
        #expect(original.grainAmount == 0 && original.halationAmount == 0 && original.bloomAmount == 0)
    }

    @Test func decodingAnOldRecipeKeepsStoredValues() throws {
        let json = #"{"filmID":"x","grainAmount":0.9,"halationAmount":0.1,"bloomAmount":0.3}"#
        let r = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(r.grainAmount == 0.9 && r.halationAmount == 0.1 && r.bloomAmount == 0.3)
    }

    @Test func bloomFamilyDefaultsAndOverride() {
        func b(_ f: FilmFamily, mono: Bool = false) -> Double { FilmCharacter.defaults(family: f, iso: 400, monochrome: mono).bloom }
        #expect(b(.colorNegative) == 1.0 && b(.slide) == 1.4 && b(.kodachrome) == 1.2 && b(.motionPicture) == 1.2)
        #expect(b(.blackAndWhite) == 0.4 && b(.instant) == 1.6 && b(.print) == 0.8 && b(.instant, mono: true) == 0.8)
        #expect(FilmCharacter.generic.applying(.init(bloom: 2)).bloom == 2)
    }

    @Test func bloomScalesWithFilmCharacterInPipeline2() throws {
        let library = try SyntheticFilms.library([.init(id: "slide", family: .slide), .init(id: "bw", family: .blackAndWhite)])
        let r = Renderer(library: library)
        let input = PipelineFixture.linearImage(width: 128, height: 128) { x, y in
            let v: Float = (x > 54 && x < 74 && y > 54 && y < 74) ? 4 : 0.2
            return (v, v, v)
        }
        func probe(_ id: String, _ amount: Double) -> Double {
            let base = LinearPixels(r.apply(Recipe(filmID: id), to: input))
            let out = LinearPixels(r.apply(Recipe(filmID: id, bloomAmount: amount), to: input))
            return abs(out.luma(53, 64) - base.luma(53, 64))
        }
        let s = probe("slide", 0.5), b = probe("bw", 0.5)
        #expect(s > b * 1.5, "slide \(s) bw \(b)")
        #expect(probe("slide", 0.5) > 0)
    }
}
