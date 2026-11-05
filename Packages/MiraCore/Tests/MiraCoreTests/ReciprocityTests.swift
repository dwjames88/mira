import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

@Suite struct ReciprocityTests {
    static let library: FilmLibrary = {
        // swiftlint:disable:next force_try
        try! FilmLibrary(directory: FilmTests.filmsDirectory())
    }()

    static func film(_ id: String) -> Film { library.film(id: id)! }
    static let context = Renderer.makeContext()

    // MARK: Model

    @Test func schwarzschildMatchesIlfordPublishedExample() throws {
        // Ilford, Dec 2023: HP5+ (P = 1.31), 10 s -> 10^1.31 = 20.4 s.
        let hp5 = Self.film("ilford-hp5-plus-400")
        let e = Reciprocity.effect(film: hp5, exposureTime: 10)
        let corrected = 10 * exp2(e.lossStops)
        #expect(abs(corrected - 20.4) < 0.05, "corrected \(corrected)")
        #expect(!e.beyondDatasheet)
    }

    @Test func schwarzschildMatchesResearchTestVectors() throws {
        let vectors: [(String, [(Double, Double)])] = [
            ("ilford-hp5-plus-400", [(2, 2.48), (5, 8.23), (10, 20.42), (30, 86.11), (60, 213.49), (120, 529.33)]),
            ("ilford-fp4-plus-125", [(2, 2.39), (5, 7.6), (10, 18.2), (30, 72.64), (60, 173.97), (120, 416.65)]),
            ("ilford-delta-400", [(2, 2.66), (5, 9.67), (10, 25.7), (30, 120.99), (60, 321.51), (120, 854.37)]),
            ("ilford-sfx-200", []),
        ]
        for (id, rows) in vectors where Self.library.film(id: id) != nil {
            let film = Self.film(id)
            for (t, tc) in rows {
                let corrected = t * exp2(Reciprocity.effect(film: film, exposureTime: t).lossStops)
                #expect(abs(corrected - tc) / tc < 0.005, "\(id) \(t) s: \(corrected) vs \(tc)")
            }
            // One second or less: no compensation.
            #expect(Reciprocity.effect(film: film, exposureTime: 1) == .none)
        }
    }

    @Test func tableInterpolatesLinearlyInLogTime() throws {
        // Tri-X: 1 s +1, 10 s +2, 100 s +3 stops; no correction up to 0.1 s.
        let trix = Self.film("kodak-tri-x-400")
        func loss(_ t: Double) -> Double { Reciprocity.effect(film: trix, exposureTime: t).lossStops }
        #expect(abs(loss(1) - 1) < 1e-9 && abs(loss(10) - 2) < 1e-9 && abs(loss(100) - 3) < 1e-9)
        #expect(abs(loss(sqrt(10)) - 1.5) < 1e-9)  // half a decade between rows
        #expect(abs(loss(sqrt(0.1 * 1)) - 0.5) < 1e-9)  // anchor (0.1 s, 0) -> (1 s, +1)
        #expect(loss(0.1) == 0 && loss(0.01) == 0)
        // Between 0.1 s and 1 s the loss grows monotonically.
        var last = 0.0
        for i in 1...20 {
            let l = loss(0.1 * pow(10, Double(i) / 20))
            #expect(l >= last)
            last = l
        }
        // Inside the published range: not beyond the datasheet.
        #expect(!Reciprocity.effect(film: trix, exposureTime: 100).beyondDatasheet)
    }

    @Test func notRecommendedExtrapolatesAndFlagsBeyondDatasheet() throws {
        // Velvia 50: 16 s +2/3, 32 s +1, 64 s not recommended: extrapolated from the last two rows.
        let velvia = Self.film("fuji-velvia-50")
        let at32 = Reciprocity.effect(film: velvia, exposureTime: 32)
        #expect(abs(at32.lossStops - 1) < 1e-3 && !at32.beyondDatasheet)
        let at64 = Reciprocity.effect(film: velvia, exposureTime: 64)
        #expect(at64.beyondDatasheet)
        #expect(abs(at64.lossStops - (1 + 1.0 / 3)) < 2e-3, "extrapolated \(at64.lossStops)")
        // Portra 400: "none to 10 s", 100 s not recommended, no other number: beyond datasheet after 10 s.
        let portra = Self.film("kodak-portra-400")
        #expect(!Reciprocity.effect(film: portra, exposureTime: 10).beyondDatasheet)
        let p30 = Reciprocity.effect(film: portra, exposureTime: 30)
        #expect(p30.beyondDatasheet && p30.lossStops > 0)
    }

    @Test func castInvertsTheRecommendedFilter() throws {
        let velvia = Self.film("fuji-velvia-50")
        let e = Reciprocity.effect(film: velvia, exposureTime: 30)
        // Magenta filters (green absorbed): without them green is the layer that holds up, red and blue fail.
        #expect(e.cast.g > 0 && e.cast.r < 0 && e.cast.b < 0)
        let lumaMean = 0.2126 * e.cast.r + 0.7152 * e.cast.g + 0.0722 * e.cast.b
        #expect(abs(lumaMean) < 1e-9)
        // Vision3 500T, 10 s: CC10R -> red loses ~0.26 stop more, green and blue gain 0.07.
        let cine = Reciprocity.effect(film: Self.film("vision3-500t"), exposureTime: 10)
        #expect(abs(cine.lossStops - 1) < 1e-9)
        #expect(abs(cine.cast.r + 0.261) < 0.005 && abs(cine.cast.g - 0.071) < 0.005 && abs(cine.cast.b - 0.071) < 0.005)
        // Colour negative has no filter data: no cast. A monochrome film never has one.
        #expect(Reciprocity.effect(film: Self.film("kodak-portra-400"), exposureTime: 30).cast == .zero)
        #expect(Reciprocity.effect(film: Self.film("polaroid-667"), exposureTime: 10).cast == .zero)
        // Family default (no table): 250D uses the motion-picture default.
        let d250 = Reciprocity.effect(film: Self.film("vision3-250d"), exposureTime: 10)
        #expect(abs(d250.lossStops - 1) < 1e-9 && d250.cast.r < 0)
    }

    @Test func contrastAndShadowGrainGrowWithTime() throws {
        for id in ["kodak-tri-x-400", "fuji-velvia-50", "kodak-portra-400"] {
            let film = Self.film(id)
            var lastContrast = 1.0, lastGrain = 1.0
            for t in [0.5, 2, 8, 30] as [Double] {
                let e = Reciprocity.effect(film: film, exposureTime: t)
                #expect(e.contrastGain >= lastContrast && e.shadowGrainGain >= lastGrain, "\(id) \(t)")
                lastContrast = e.contrastGain; lastGrain = e.shadowGrainGain
            }
            #expect(lastContrast > 1.01 && lastGrain > 1.1, "\(id)")
        }
        // Tri-X: 0.10 per stop of loss (Kodak -10 % development per stop).
        let e = Reciprocity.effect(film: Self.film("kodak-tri-x-400"), exposureTime: 10)
        #expect(abs(e.contrastGain - 1.2) < 1e-9)
        #expect(abs(e.shadowGrainGain - exp2(1)) < 1e-9)
        // Capped at 2x.
        #expect(Reciprocity.effect(film: Self.film("kodak-tri-x-400"), exposureTime: 3000).shadowGrainGain == 2)
    }

    @Test func highIntensityFailureOnlyWherePublished() throws {
        let trix = Self.film("kodak-tri-x-400")
        let fast = Reciprocity.effect(film: trix, exposureTime: 1e-5)
        #expect(abs(fast.lossStops - 1) < 1e-9 && fast.contrastGain < 1 && fast.cast == .zero)
        #expect(Reciprocity.effect(film: trix, exposureTime: 1e-3) == .none)
        #expect(Reciprocity.effect(film: Self.film("fuji-velvia-50"), exposureTime: 1e-4) == .none)
    }

    @Test func variantsInheritTheirStocksData() throws {
        let lib = Self.library
        for film in lib.films {
            guard let parent = film.parent, let p = lib.film(id: parent) else { continue }
            #expect(film.reciprocity == p.reciprocity, "\(film.id)")
        }
        #expect(Self.film("kodak-tri-x-400-plus-1").reciprocity == Self.film("kodak-tri-x-400").reciprocity)
        #expect(Self.film("kodak-tri-x-400").reciprocity != nil)
    }

    @Test func everyFilmIsAnExactNoOpAtOneOver125() throws {
        for film in Self.library.films {
            for t in [1.0 / 125, 1.0 / 250, 1.0 / 1000 * 2] {
                let e = Reciprocity.effect(film: film, exposureTime: t)
                #expect(e == .none, "\(film.id) at \(t) s: \(e)")
            }
        }
        for family in FilmFamily.allCases {
            let film = Film(id: "x", displayName: "x", brand: "x", family: family, iso: 400, description: "", file: "x")
            #expect(Reciprocity.effect(film: film, exposureTime: 1.0 / 125) == .none, "\(family)")
        }
    }

    @Test func dataBlocksDecodeAndRoundTrip() throws {
        let json = #"{"type":"table","noCorrectionUpTo":1,"rows":[[4,0.33,{"r":0,"g":0.17,"b":0}],[64,null,null]],"highIntensity":[[0.001,0]],"source":"u"}"#
        let d = try JSONDecoder().decode(ReciprocityData.self, from: Data(json.utf8))
        #expect(d.rows?.count == 2 && d.rows?[0].cc?.g == 0.17 && d.rows?[1].stops == nil && d.rows?[1].cc == nil)
        let back = try JSONDecoder().decode(ReciprocityData.self, from: JSONEncoder().encode(d))
        #expect(back == d)
        // Old films.json entries (no block) still decode.
        let old = #"{"id":"a","displayName":"A","brand":"b","family":"slide","iso":100,"file":"f"}"#
        #expect(try JSONDecoder().decode(Film.self, from: Data(old.utf8)).reciprocity == nil)
    }

    // MARK: Kernel

    @Test func kernelMatchesFilmMath() throws {
        let n = 64
        let ramp = PipelineFixture.linearImage(width: n, height: 1) { x, _ in
            let v = 1.5 * Float(x) / Float(n - 1)
            return (v, v * 0.5, v * 0.25)
        }
        let gain = (r: 0.7, g: 1.1, b: 0.9)
        for contrast in [1.0, 1.2, 0.8] {
            let out = LinearPixels(GradeKernels.applyReciprocity(gain: gain, contrast: contrast, to: ramp))
            let src = LinearPixels(ramp)
            for x in 0..<n {
                for (c, g) in [gain.r, gain.g, gain.b].enumerated() {
                    let expect = FilmMath.reciprocity(src.value(x, 0, c), gain: g, contrast: contrast)
                    #expect(abs(out.value(x, 0, c) - expect) < 2e-3 + 2e-3 * abs(expect), "x=\(x) c=\(c) k=\(contrast)")
                }
            }
        }
        // Mid grey stays put under the contrast power.
        #expect(abs(FilmMath.reciprocity(0.18, gain: 1, contrast: 1.4) - 0.18) < 1e-12)
    }

    @Test func shadowGainOnlyRaisesGrainInShadows() throws {
        // The kernel adds noise to whatever values it is given; feed it values already in the 0...1 "encoded" range.
        let input = PipelineFixture.linearImage(width: 1000, height: 400) { x, _ in
            let v: Float = x < 500 ? 0.04 : 0.55
            return (v, v, v)
        }
        func stds(_ gain: Double) -> (Double, Double) {
            // Negative shape: noise in the shadows needs the clear base behind it, so use mid-dark (0.25) and light (0.75).
            let params = GrainModel.Parameters(tau: 8, lattice: 10, amplitude: 0.1, pitch: 6)
            let out = LinearPixels(GradeKernels.applyGrain(params, seed: 7, clumping: 0, layerCorrelation: 1,
                                                           shape: .negative, shadowGain: gain, shadowCenter: 0.6, to: input))
            func sd(_ xs: Range<Int>) -> Double {
                var v: [Double] = []
                for y in 20..<380 { for x in xs { v.append(out.value(x, y, 1)) } }
                return stddev(v)
            }
            return (sd(50..<450), sd(550..<950))
        }
        let base = stds(1), boosted = stds(2)
        #expect(base.0 > 0.003, "grain present: \(base.0)")
        #expect(boosted.0 > base.0 * 1.3, "shadows \(base.0) -> \(boosted.0)")
        #expect(abs(boosted.1 - base.1) < base.1 * 0.05 + 1e-4, "highlights \(base.1) -> \(boosted.1)")
        #expect(FilmMath.shadowWeight(luma: 0, center: 0.4) == 1 && FilmMath.shadowWeight(luma: 0.6, center: 0.4) == 0)
    }

    // MARK: Render

    func renderMeans(_ r: Renderer, _ recipe: Recipe, exif: Double?, gray: CGFloat = 0.45) -> (r: Double, g: Double, b: Double, luma: Double) {
        let out = Pixels(r.apply(recipe, to: PipelineFixture.flat(gray, width: 64, height: 64), sourceExposureTime: exif), context: Self.context)
        let l = out.luma
        return (mean(out.channel(0)), mean(out.channel(1)), mean(out.channel(2)), mean(l))
    }

    @Test func uncompensatedDarkensMonotonicallyOnTriX() throws {
        let r = Renderer(library: Self.library)
        var last = Double.infinity
        for t in [0.01, 1, 10, 100] as [Double] {
            let m = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", reciprocity: .uncompensated), exif: t).luma
            #expect(m <= last + 1e-9, "t=\(t): \(m) vs \(last)")
            if t >= 1 { #expect(m < last - 0.005, "t=\(t) should be darker: \(m) vs \(last)") }
            last = m
        }
        // Off and nil time are the unmodified render.
        let plain = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", reciprocity: .off), exif: 100)
        let none = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", reciprocity: .uncompensated), exif: nil)
        let fast = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", reciprocity: .uncompensated), exif: 1.0 / 125)
        #expect(plain.luma == none.luma && plain.luma == fast.luma)
    }

    @Test func recipeTimeOverridesExif() throws {
        let r = Renderer(library: Self.library)
        let a = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", exposureTime: 10, reciprocity: .uncompensated), exif: 1.0 / 125)
        let b = renderMeans(r, Recipe(filmID: "kodak-tri-x-400", reciprocity: .uncompensated), exif: 10)
        #expect(a.luma == b.luma)
    }

    @Test func compensatedKeepsLuminanceAndShiftsColourOnVelvia() throws {
        let r = Renderer(library: Self.library)
        let off = renderMeans(r, Recipe(filmID: "fuji-velvia-50", reciprocity: .off), exif: 30)
        let comp = renderMeans(r, Recipe(filmID: "fuji-velvia-50", reciprocity: .compensated), exif: 30)
        #expect(abs(comp.luma - off.luma) / off.luma < 0.03, "luma \(off.luma) -> \(comp.luma)")
        // Green-shifted: green rises, red and blue fall.
        #expect(comp.g - off.g > 0.002, "green \(off.g) -> \(comp.g)")
        #expect(comp.r < off.r && comp.b < off.b, "r \(off.r)->\(comp.r) b \(off.b)->\(comp.b)")
        #expect(comp.g - comp.r > off.g - off.r && comp.g - comp.b > off.g - off.b)
        // Uncompensated is darker than compensated.
        let un = renderMeans(r, Recipe(filmID: "fuji-velvia-50", reciprocity: .uncompensated), exif: 30)
        #expect(un.luma < comp.luma - 0.01)
    }

    @Test func contrastIncreasesWithTime() throws {
        let lib = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let r = Renderer(library: lib)
        let ramp = PipelineFixture.halves(0.3, 0.6, size: 400)
        func spread(_ t: Double) -> Double {
            let out = Pixels(r.apply(Recipe(filmID: "neg", reciprocity: .compensated), to: ramp, sourceExposureTime: t), context: Self.context)
            return mean(PipelineFixture.rect(out, x: 250..<390, y: 10..<390)) - mean(PipelineFixture.rect(out, x: 10..<150, y: 10..<390))
        }
        let s1 = spread(1.0 / 125), s10 = spread(10), s100 = spread(100)
        #expect(s10 > s1 + 0.005 && s100 > s10 + 0.005, "\(s1) \(s10) \(s100)")
    }

    @Test func pipelineOneIgnoresReciprocity() throws {
        let r = Renderer(library: Self.library)
        let a = Recipe(filmID: "kodak-tri-x-400", pipeline: 1, reciprocity: .uncompensated)
        let b = Recipe(filmID: "kodak-tri-x-400", pipeline: 1, reciprocity: .off)
        #expect(renderMeans(r, a, exif: 100).luma == renderMeans(r, b, exif: 100).luma)
    }

    // MARK: Recipe

    @Test func recipeRoundTripAndLegacyDecode() throws {
        var recipe = Recipe(filmID: "kodak-tri-x-400", exposureTime: 8, reciprocity: .uncompensated)
        let back = try Recipe.decode(recipe.encoded())
        #expect(back.exposureTime == 8 && back.reciprocity == .uncompensated && back == recipe)
        // Defaults are not written, so older bytes are unchanged.
        recipe = Recipe(filmID: "kodak-tri-x-400")
        let text = String(decoding: try recipe.encoded(), as: UTF8.self)
        #expect(!text.contains("exposureTime") && !text.contains("reciprocity"))
        // A legacy recipe has the defaults; an unknown mode falls back to the default.
        let legacy = try Recipe.decode(Data(#"{"filmID":"a","strength":1}"#.utf8))
        #expect(legacy.exposureTime == nil && legacy.reciprocity == .compensated)
        let future = try Recipe.decode(Data(#"{"filmID":"a","reciprocity":"turbo"}"#.utf8))
        #expect(future.reciprocity == .compensated)
        // Film-science controls (format 4) include them when set.
        #expect(!Recipe().usesFilmScienceControls)
        #expect(Recipe(exposureTime: 2).usesFilmScienceControls)
        #expect(Recipe(reciprocity: .off).usesFilmScienceControls)
        #expect(MiraAdjustment.formatVersion(for: Recipe(pipeline: 1, exposureTime: 2)) == MiraAdjustment.filmScienceFormatVersion)
    }

    // MARK: EXIF

    static func fixture(_ path: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(path)
    }

    @Test func exposureTimeFromFixtures() throws {
        let jpg = Self.fixture("Fixtures/sample.jpg")
        let dng = Self.fixture("Fixtures/raw/iphone-xs.dng")
        let tJPG = ImageSource.exposureTime(url: jpg)
        let tDNG = ImageSource.exposureTime(url: dng)
        // Recorded values: sample.jpg carries no exposure time; the iPhone XS DNG was shot at 1/450 s.
        #expect(tJPG == nil)
        #expect(tDNG != nil && abs(tDNG! - 1.0 / 450) < 1e-6)
        // The loaded image carries the tag.
        #expect(ImageSource.load(url: jpg)?.miraExposureTime == tJPG)
        #expect(ImageSource.loadDecoded(url: jpg)?.miraExposureTime == tJPG)
        #expect(ImageSource.loadThumbnail(url: jpg, maxPixelSize: 200)?.miraExposureTime == tJPG)
        #expect(ImageSource.load(url: dng)?.miraExposureTime == tDNG)
        let developed = ImageSource.developedSource(url: dng, recipe: Recipe(filmID: "x"), draft: true)
        #expect(developed?.miraExposureTime == tDNG)
    }

    @Test func exposureTimeIsNilWithoutExif() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noexif-\(UUID().uuidString).png")
        let cg = Self.context.createCGImage(PipelineFixture.flat(0.5, width: 8, height: 8), from: CGRect(x: 0, y: 0, width: 8, height: 8))!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        #expect(ImageSource.exposureTime(url: url) == nil)
        #expect(ImageSource.load(url: url)?.miraExposureTime == nil)
        #expect(ImageSource.exposureTime(url: url.appendingPathExtension("missing")) == nil)
        #expect(ImageSource.exposureTime(properties: [:]) == nil)
        // A zero or negative value is not an exposure time.
        let bad: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.0]]
        #expect(ImageSource.exposureTime(properties: bad) == nil)
    }
}
