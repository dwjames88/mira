import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct ProceduralLooksTests {
    static func params(_ id: String) -> ProceduralLooks.Params { ProceduralLooks.parameters[id]! }
    static func tone(_ id: String, _ g: Double) -> SIMD3<Double> { ProceduralLooks.transform(params(id), [g, g, g]) }
    static func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    /// Slope of the neutral luminance response at encoded mid-gray (0.5).
    static func midSlope(_ id: String) -> Double {
        (luma(tone(id, 0.55)) - luma(tone(id, 0.45))) / 0.1
    }

    @Test func idsAreRegisteredAndCataloged() throws {
        #expect(Set(ProceduralLooks.ids) == Set(ProceduralLooks.parameters.keys))
        let lib = try FilmLibrary(directory: FilmTests.filmsDirectory())
        for id in ProceduralLooks.ids {
            let film = try #require(lib.film(id: id))
            #expect(film.proceduralID == id)
            #expect(film.brand == "Mira" && film.source == nil)
        }
        #expect(lib.film(id: "vision3-500t")?.family == .motionPicture)
        #expect(lib.film(id: "cinema-print")?.family == .print)
        #expect(lib.film(id: "vision3-500t")?.resolvedCharacter.remJet == true)
        let g500 = try #require(lib.film(id: "vision3-500t")?.resolvedCharacter.grainStrength)
        let g250 = try #require(lib.film(id: "vision3-250d")?.resolvedCharacter.grainStrength)
        #expect(g250 < g500)
        #expect(throws: LUTError.self) { try ProceduralLooks.lut("nope") }
    }

    /// Blacks (encoded 0) land below 0.12 luma (500T lifts to about 0.10), whites above 0.85.
    /// Mid-gray (encoded 0.5) must stay plausible: 500T 0.44...0.58, 250D 0.44...0.58, Cinema Print and
    /// Color Paper 0.42...0.60. Neutral luminance is monotone along the gray axis, everything finite and in 0...1.
    @Test func lutsAreFiniteMonotoneAndPlausible() throws {
        for id in ProceduralLooks.ids {
            let lut = try ProceduralLooks.lut(id)
            #expect(lut.dimension == 64 && lut.data.count == 64 * 64 * 64 * 16)
            let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            #expect(floats.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(id)")
            var prev = -1.0
            for i in 0..<64 {
                let o = ((i * 64 + i) * 64 + i) * 4
                let y = Self.luma([Double(floats[o]), Double(floats[o + 1]), Double(floats[o + 2])])
                #expect(y >= prev - 1e-6, "\(id): luminance falls at step \(i)")
                prev = y
            }
            let mid = Self.luma(Self.tone(id, 0.5))
            #expect((0.42...0.60).contains(mid), "\(id): mid-gray \(mid)")
            #expect(Self.luma(Self.tone(id, 0)) < 0.12, "\(id): blacks")
            #expect(Self.luma(Self.tone(id, 1)) > 0.85, "\(id): whites")
        }
    }

    @Test func lutsAreCachedAndMatchTheTransform() throws {
        let a = try ProceduralLooks.lut("cinema-print"), b = try ProceduralLooks.lut("cinema-print")
        #expect(a.data == b.data)
        let floats = a.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let o = ((10 * 64 + 30) * 64 + 50) * 4   // b=10, g=30, r=50
        let v = ProceduralLooks.transform(Self.params("cinema-print"), [50.0 / 63, 30.0 / 63, 10.0 / 63])
        #expect(abs(Double(floats[o]) - v.x) < 1e-6 && abs(Double(floats[o + 2]) - v.z) < 1e-6)
    }

    @Test func contrastOrdering() {
        #expect(Self.midSlope("vision3-500t") < Self.midSlope("vision3-250d"))
        #expect(Self.midSlope("cinema-print") > Self.midSlope("color-paper"))
        #expect(Self.midSlope("vision3-500t") < 1)
        #expect(Self.midSlope("cinema-print") > 1.2)
    }

    @Test func tungstenNegativeMakesDaylightGrayBluer() {
        let g = Self.tone("vision3-500t", 0.5)
        #expect(g.z > g.x, "500T gray b \(g.z) vs r \(g.x)")
        let d = Self.tone("vision3-250d", 0.5)
        #expect(abs(d.z - d.x) < 0.02, "250D stays neutral")
        // Highlights are warm in the split balance of the daylight stock.
        let hi = Self.tone("vision3-250d", 0.9)
        #expect(hi.x > hi.z)
    }

    // MARK: Paper stage

    @Test func paperStageEqualsTheCardAfterAnIdentityFilm() throws {
        let cards = try FilmLibrary(directory: FilmTests.filmsDirectory())
        let identity = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let input = Fixture.gradientAndPatches(size: 128)
        let ctx = Renderer.makeContext()
        for (paper, card) in [(PaperProfile.cinemaPrint, "cinema-print"), (.colorPaper, "color-paper")] {
            let viaCard = Pixels(Renderer(library: cards).apply(Recipe(filmID: card), to: input), context: ctx)
            let viaPaper = Pixels(Renderer(library: identity).apply(Recipe(filmID: "neg", paper: paper), to: input), context: ctx)
            var worst = 0
            for i in 0..<viaCard.rgba.count { worst = max(worst, abs(Int(viaCard.rgba[i]) - Int(viaPaper.rgba[i]))) }
            #expect(worst <= 2, "\(card): max channel difference \(worst)/255")
        }
        // And it changes the picture.
        let plain = Pixels(Renderer(library: identity).apply(Recipe(filmID: "neg"), to: input), context: ctx)
        let printed = Pixels(Renderer(library: identity).apply(Recipe(filmID: "neg", paper: .cinemaPrint), to: input), context: ctx)
        #expect(plain.rgba != printed.rgba)
    }

    @Test func paperSetIgnoresTheScanProfile() throws {
        let identity = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let r = Renderer(library: identity)
        let input = Fixture.gradientAndPatches(size: 96)
        let ctx = Renderer.makeContext()
        let a = Pixels(r.apply(Recipe(filmID: "neg", scanProfile: .frontier, paper: .colorPaper), to: input), context: ctx)
        let b = Pixels(r.apply(Recipe(filmID: "neg", scanProfile: .neutral, paper: .colorPaper), to: input), context: ctx)
        #expect(a.rgba == b.rgba)
        // The scan still applies when there is no paper.
        let s = Pixels(r.apply(Recipe(filmID: "neg", scanProfile: .frontier), to: input), context: ctx)
        let n = Pixels(r.apply(Recipe(filmID: "neg"), to: input), context: ctx)
        #expect(s.rgba != n.rgba)
    }

    @Test func pushContrastStillAppliesWithPaper() throws {
        let identity = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let r = Renderer(library: identity)
        let input = Fixture.gradientAndPatches(size: 96)
        let ctx = Renderer.makeContext()
        let base = Pixels(r.apply(Recipe(filmID: "neg", paper: .colorPaper), to: input), context: ctx)
        let pushed = Pixels(r.apply(Recipe(filmID: "neg", push: 2, paper: .colorPaper), to: input), context: ctx)
        #expect(base.rgba != pushed.rgba)
    }
}
