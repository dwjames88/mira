import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import MiraCore

/// Exposure time must change the picture through the public paths the apps use (`Renderer.apply`, the live
/// `PreviewEngine`, the contact sheet), not only in the kernel tests.
@Suite struct ReciprocityAppPathTests {
    static let library = ReciprocityTests.library
    static let context = Renderer.sharedContext
    static let renderer = Renderer(library: library)

    // MARK: Chart

    /// Mid-grey (linear 0.18, the reciprocity contrast pivot) plus colour and grey patches, 8 x 2 patches of 60 px.
    struct Chart {
        static let patch = 60
        static let colors: [[CGFloat]] = [
            [0.4614, 0.4614, 0.4614],                                  // 0: 18 % grey
            [0.8, 0.2, 0.2], [0.2, 0.7, 0.3], [0.2, 0.3, 0.85], [0.9, 0.8, 0.2],
            [0.85, 0.6, 0.5], [0.3, 0.2, 0.15], [0.9, 0.9, 0.9],
            [0.1, 0.1, 0.1], [0.25, 0.25, 0.25], [0.65, 0.65, 0.65], [0.5, 0.2, 0.6],
            [0.2, 0.5, 0.5], [0.7, 0.4, 0.1], [0.4, 0.4, 0.8], [0.95, 0.95, 0.95],
        ]
        static var image: CIImage {
            let w = 8 * patch, h = 2 * patch
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, c) in colors.enumerated() {
                ctx.setFillColor(CGColor(colorSpace: space, components: c + [1])!)
                // Row 0 is the top row in memory = the upper half in CG.
                let x = (i % 8) * patch, y = (1 - i / 8) * patch
                ctx.fill(CGRect(x: x, y: y, width: patch, height: patch))
            }
            return CIImage(cgImage: ctx.makeImage()!)
        }
        /// Mean RGB (0...1, sRGB encoded) of the centre of patch `i`.
        static func mean(_ px: Pixels, patch i: Int) -> (r: Double, g: Double, b: Double) {
            let x0 = (i % 8) * patch + 15, y0 = (i / 8) * patch + 15
            var s = (0.0, 0.0, 0.0), n = 0.0
            for y in y0..<(y0 + 30) { for x in x0..<(x0 + 30) {
                let o = (y * px.width + x) * 4
                s.0 += Double(px.rgba[o]); s.1 += Double(px.rgba[o + 1]); s.2 += Double(px.rgba[o + 2]); n += 1
            } }
            return (s.0 / n / 255, s.1 / n / 255, s.2 / n / 255)
        }
    }

    static func pixels(_ recipe: Recipe, source: CIImage = Chart.image, exif: Double? = nil) -> Pixels {
        Pixels(renderer.apply(recipe, to: source, sourceExposureTime: exif), context: context)
    }

    static func lum(_ m: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * m.r + 0.7152 * m.g + 0.0722 * m.b }
    static func max8(_ a: Pixels, _ b: Pixels) -> Int {
        zip(a.rgba, b.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// A recipe as `EditorModel.selectFilm` makes it: the film on the current pipeline, everything else default.
    static func recipe(_ id: String, time: Double?, _ mode: ReciprocityMode = .compensated,
                       strength: Double = 1) -> Recipe {
        var r = Recipe(filmID: id, pipeline: Recipe.legacyPipeline)
        r.filmID = id
        r.pipeline = Recipe.currentPipeline
        r.exposureTime = time
        r.reciprocity = mode
        r.reciprocityStrength = strength
        return r
    }

    // MARK: Renderer.apply

    @Test(arguments: ["kodak-portra-400", "fuji-velvia-50"])
    func uncompensatedDarkensByTheDatasheetLoss(id: String) throws {
        let film = Self.library.film(id: id)!
        let loss = Reciprocity.effect(film: film, exposureTime: 30).lossStops
        #expect(loss > 0.25)
        let fast = Self.pixels(Self.recipe(id, time: 1.0 / 125, .uncompensated))
        let off = Self.pixels(Self.recipe(id, time: 30, .off))
        #expect(Self.max8(fast, off) == 0, "1/125 s changes nothing")
        let slow = Self.pixels(Self.recipe(id, time: 30, .uncompensated))
        // Reference: the same film with the exposure lowered by the lost stops, bracketed by +-0.15 stop.
        func reference(_ stops: Double) -> Double {
            var r = Self.recipe(id, time: nil, .off)
            r.exposure = stops
            return Self.lum(Chart.mean(Self.pixels(r), patch: 0))
        }
        let measured = Self.lum(Chart.mean(slow, patch: 0))
        #expect(measured < Self.lum(Chart.mean(off, patch: 0)) - 0.02, "darker than 1/125 s")
        #expect(measured >= reference(-loss - 0.15) - 0.004 && measured <= reference(-loss + 0.15) + 0.004,
                "\(id): grey \(measured) vs \(reference(-loss - 0.15))...\(reference(-loss + 0.15)) for \(loss) stops")
    }

    @Test func compensatedVelviaChangesTheGreyBalance() throws {
        let id = "fuji-velvia-50"
        let off = Chart.mean(Self.pixels(Self.recipe(id, time: 30, .off)), patch: 0)
        let comp = Chart.mean(Self.pixels(Self.recipe(id, time: 30, .compensated)), patch: 0)
        func gm(_ m: (r: Double, g: Double, b: Double)) -> Double { m.g - 0.5 * (m.r + m.b) }
        #expect(abs(gm(comp) - gm(off)) * 255 > 2, "G/M balance moved by \(abs(gm(comp) - gm(off)) * 255)/255")
    }

    @Test func compensatedPortraContrastGrowsWithStrength() throws {
        let id = "kodak-portra-400"
        func chartStd(_ p: Pixels) -> Double { stddev((0..<16).map { Self.lum(Chart.mean(p, patch: $0)) }) }
        let off = chartStd(Self.pixels(Self.recipe(id, time: 30, .off)))
        let one = chartStd(Self.pixels(Self.recipe(id, time: 30, .compensated)))
        let two = chartStd(Self.pixels(Self.recipe(id, time: 30, .compensated, strength: 2)))
        #expect(two - off > 0.004, "std off \(off), x1 \(one), x2 \(two)")
        #expect(one > off && two > one)
    }

    @Test(arguments: ["kodak-portra-400", "fuji-velvia-50"])
    func strengthZeroEqualsOff(id: String) throws {
        let off = Self.pixels(Self.recipe(id, time: 30, .off))
        #expect(Self.max8(Self.pixels(Self.recipe(id, time: 30, .compensated, strength: 0)), off) == 0)
        #expect(Self.max8(Self.pixels(Self.recipe(id, time: 30, .uncompensated, strength: 0)), off) == 0)
        #expect(Self.max8(Self.pixels(Self.recipe(id, time: 30, .compensated, strength: 2)), off) > 0)
    }

    @Test func theSourceExifTimeReachesTheGraph() throws {
        let id = "fuji-velvia-50"
        let viaRecipe = Self.pixels(Self.recipe(id, time: 30, .uncompensated))
        let viaExif = Self.pixels(Self.recipe(id, time: nil, .uncompensated), exif: 30)
        let tagged = Self.pixels(Self.recipe(id, time: nil, .uncompensated), source: Chart.image.withMiraExposureTime(30))
        #expect(Self.max8(viaRecipe, viaExif) == 0 && Self.max8(viaRecipe, tagged) == 0)
        // The recipe's time wins over the EXIF one.
        let override = Self.pixels(Self.recipe(id, time: 30, .uncompensated), exif: 1.0 / 125)
        #expect(Self.max8(viaRecipe, override) == 0)
    }

    @Test func legacyPipelineIgnoresTheTimeUntilUpgraded() throws {
        var legacy = Recipe(filmID: "fuji-velvia-50", pipeline: Recipe.legacyPipeline)
        let base = Self.pixels(legacy)
        legacy.exposureTime = 30; legacy.reciprocity = .uncompensated
        #expect(Self.max8(Self.pixels(legacy), base) == 0, "pipeline 1 ignores exposure time")
        legacy.exposureTime = nil; legacy.reciprocity = .compensated
        legacy.settingFilmScienceControl { $0.exposureTime = 30; $0.reciprocity = .uncompensated }
        #expect(legacy.pipeline == Recipe.currentPipeline)
        #expect(Self.max8(Self.pixels(legacy), base) > 4)
    }

    // MARK: Recipe rule

    @Test func upgradeRule() {
        var r = Recipe(filmID: "x", pipeline: Recipe.legacyPipeline)
        r.settingFilmScienceControl { $0.strength = 0.5 }
        #expect(r.pipeline == Recipe.legacyPipeline, "a legacy control is not a film-science control")
        for edit: (inout Recipe) -> Void in [
            { $0.push = 1 }, { $0.scanProfile = .frontier }, { $0.paper = .cinemaPrint }, { $0.toning = .selenium },
            { $0.toningStrength = 0.9 }, { $0.remJetRemoved = true }, { $0.exposureTime = 4 },
            { $0.reciprocity = .off }, { $0.reciprocityStrength = 2 },
        ] {
            var q = Recipe(filmID: "x", pipeline: Recipe.legacyPipeline)
            q.settingFilmScienceControl(edit)
            #expect(q.pipeline == Recipe.currentPipeline)
        }
    }

    @Test func strengthRoundTripsAndIsOmittedAtOne() throws {
        var r = Recipe(filmID: "x")
        #expect(!String(decoding: try r.encoded(), as: UTF8.self).contains("reciprocityStrength"))
        #expect(!r.usesFilmScienceControls)
        r.reciprocityStrength = 1.5
        #expect(r.usesFilmScienceControls)
        #expect(try Recipe.decode(try r.encoded()).reciprocityStrength == 1.5)
    }

    @Test func scalingTheEffect() throws {
        let film = Self.library.film(id: "fuji-velvia-50")!
        let e = Reciprocity.effect(film: film, exposureTime: 30)
        let twice = e.scaled(by: 2, mode: .compensated)
        #expect(abs(twice.cast.g - 2 * e.cast.g) < 1e-12)
        #expect(abs((twice.contrastGain - 1) - 2 * (e.contrastGain - 1)) < 1e-12)
        #expect(twice.lossStops == e.lossStops, "the compensated loss is the datasheet's")
        #expect(e.scaled(by: 2, mode: .uncompensated).lossStops == 2 * e.lossStops)
        #expect(e.scaled(by: 1, mode: .uncompensated) == e)
        #expect(e.scaled(by: 0, mode: .compensated).cast == .zero && e.scaled(by: 0, mode: .compensated).contrastGain == 1)
    }

    // MARK: Preview engine

    @Test func previewAndZoomSeeTheExposureTime() throws {
        let id = "fuji-velvia-50"
        let engine = PreviewEngine(renderer: Self.renderer, context: Self.context)
        // The source carries the EXIF time (like a loaded file); the recipe has none.
        engine.setSource(Chart.image.withMiraExposureTime(30))
        let canvas = CGSize(width: 480, height: 120)
        func preview(_ r: Recipe) throws -> Pixels {
            let frame = try #require(engine.render(r, canvas: canvas))
            return Pixels(CIImage(cgImage: try #require(frame.cgImage(context: Self.context))), context: Self.context)
        }
        let exif = try preview(Self.recipe(id, time: nil, .uncompensated))
        let off = try preview(Self.recipe(id, time: nil, .off))
        let chosen = try preview(Self.recipe(id, time: 30, .uncompensated))
        #expect(Self.max8(exif, off) > 8, "EXIF time reaches the preview")
        #expect(Self.max8(exif, chosen) == 0)
        // Zoomed: the same pixels region render.
        let region = ZoomRegion(scale: 1, rect: CGRect(x: 0, y: 0, width: 240, height: 120))
        let zoomedExif = try #require(engine.renderZoomed(Self.recipe(id, time: nil, .uncompensated), region: region))
        let zoomedOff = try #require(engine.renderZoomed(Self.recipe(id, time: nil, .off), region: region))
        let a = Pixels(CIImage(cgImage: try #require(zoomedExif.cgImage(context: Self.context))), context: Self.context)
        let b = Pixels(CIImage(cgImage: try #require(zoomedOff.cgImage(context: Self.context))), context: Self.context)
        #expect(Self.max8(a, b) > 8, "EXIF time reaches the zoomed render")
        // A legacy recipe ignores it.
        let legacy = try preview(Recipe(filmID: id, pipeline: Recipe.legacyPipeline, exposureTime: 30, reciprocity: .uncompensated))
        let legacyOff = try preview(Recipe(filmID: id, pipeline: Recipe.legacyPipeline, reciprocity: .off))
        #expect(Self.max8(legacy, legacyOff) == 0)
    }

    // MARK: Contact sheet

    @Test func contactSheetTileEqualsRendererApply() throws {
        let id = "fuji-velvia-50"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mira-cs-recip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let src = Chart.image   // 480 x 120
        let config = ContactSheet.Config(films: [id], states: [.film], tileWidth: 480, outDir: out,
                                         exposureTime: 30, reciprocity: .uncompensated)
        _ = try ContactSheet.run(config: config, library: Self.library) { _ in src }
        let png = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent("\(id).png") as CFURL, nil))
        let sheet = try #require(CGImageSourceCreateImageAtIndex(png, 0, nil))
        let layout = ContactSheetLayout(columns: 1, rows: 1, tileWidth: 480, tileHeight: 120)
        let origin = layout.origin(column: 0, row: 0)
        let tile = try #require(sheet.cropping(to: CGRect(x: origin.x, y: origin.topY, width: 480, height: 120)))
        let sheetPx = Pixels(CIImage(cgImage: tile), context: Self.context)
        var recipe = ContactSheetState.film.recipe(filmID: id)
        recipe.exposureTime = 30; recipe.reciprocity = .uncompensated
        let direct = Self.pixels(recipe, source: src)
        #expect(Self.max8(sheetPx, direct) == 0, "contact sheet differs from Renderer.apply by \(Self.max8(sheetPx, direct))/255")
    }
}
