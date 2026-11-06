import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import MiraCore
import Photos
import UniformTypeIdentifiers

// `mira-sheet --golden record|compare`: golden renders that pin the rendering behaviour down.
//
//   mira-sheet --golden record  --films <Films> --out <refdir>               [--fixtures-dir Fixtures] [--only <text>]
//   mira-sheet --golden compare --films <Films> --ref <refdir> --out <dir>   [--fixtures-dir Fixtures] [--only <text>]
//
// `record` renders every case in `Golden.specs` through the app's own code paths and writes the references plus
// `manifest.json` (case, stage, recipe JSON, code path exercised, pixel size, source) into <refdir>. `compare`
// renders everything again, prints one line per artifact (mean, 99.9th percentile and max absolute difference, and
// the number of pixels with a channel more than one level off, all in 8-bit levels per channel; a 16-bit
// reference is compared in 16-bit units divided by 257), writes diff images for failures into --out, and exits
// non-zero when any artifact is beyond tolerance, differs in size, metadata or encoded bytes, or is missing.
//
// TOLERANCES (8-bit levels per channel). See `Golden.defaultTolerance` and `Golden.tolerances`:
//   default           mean <= 0.01, max <= 1
// Measured noise floor (Apple M1 Pro, macOS 27.0 beta, 85 image artifacts): two release runs in separate processes and one debug
// build all reproduced the reference bit for bit (mean 0, max 0), grain, halation, blurs and RAW decode included. The tolerance is
// therefore not noise headroom: it only lets a driver or OS update move an isolated pixel by one level. A refactor that changes
// pixels in a way that shows up in the mean (> 0.01 level) or anywhere by more than one level is a rendering change.
// Text artifacts (export metadata, encoded recipe / adjustment data / preset bytes) have NO tolerance: any change fails.
//
// Stages (what each artifact exercises):
//   preview  PreviewEngine.previewBase + Renderer.grade at the 1500x1000 canvas, rendered to 16-bit sRGB (the preview
//            graph exactly as PreviewEngine.render grades it, minus the 8-bit hand-off, so sub-level changes show)
//   frame    PreviewEngine.render itself (the IOSurface BGRA8 frame the Mac canvas shows), 8-bit
//   export   Renderer.apply + CIContext.createCGImage at the source's native size, as Renderer.export does, 8-bit
//   proxy    iOS live preview: PreviewProxy.make at an iPhone 16 Pro box, then Renderer.apply, 16-bit
//   thumb    film-strip card tile: PreviewEngine.renderThumbnails (no disk cache), 8-bit
//   file     Renderer.export to JPEG / HEIC / TIFF: decoded pixels (8-bit) and the written metadata dictionary
//   codec    the bytes the app persists for the recipe (Recipe.encoded, Photos adjustment data, preset file)

enum Golden {
    struct Tolerance {
        var mean: Double
        var max: Double
        var note: String?
    }

    /// Applies to every artifact without an entry in `tolerances`.
    static let defaultTolerance = Tolerance(mean: 0.01, max: 1, note: nil)

    /// Per-artifact overrides, keyed by artifact id (`name/stage`). Each needs a documented reason.
    static let tolerances: [String: Tolerance] = [:]

    enum Src: String {
        case sample, tagged, heic, raw
    }

    enum Stage: String {
        case preview, frame, export, proxy
    }

    /// One row of the case table.
    struct Spec {
        var name: String
        var recipe: Recipe
        var source: Src = .sample
        var stages: [Stage] = [.preview]
        /// RAW only: the first-frame draft decode (`RawOpener.openDraft`) instead of the refined preview decode.
        var rawDraft = false
    }

    /// The stock ids the table uses, picked deterministically from the library.
    struct Stocks {
        var byFamily: [FilmFamily: String]
        var colourNegative: String { byFamily[.colorNegative]! }
        var mono: String { byFamily[.blackAndWhite]! }
        var motionPicture: String { byFamily[.motionPicture]! }

        /// The first stock (card order) of every family.
        init(library: FilmLibrary) throws {
            var map: [FilmFamily: String] = [:]
            for family in FilmFamily.displayOrder {
                guard let film = library.stocks.first(where: { $0.family == family }) ?? library.films.first(where: { $0.family == family })
                else { throw GoldenError("no film in family \(family.rawValue)") }
                map[family] = film.id
            }
            byFamily = map
        }
    }

    // MARK: The case table

    /// Every recipe case. Recipes are built in code and are deterministic. A film's "default recipe" is what the app
    /// gives a newly chosen film: the current pipeline with the film's native grain, halation and bloom.
    static func specs(_ stocks: Stocks) -> [Spec] {
        func look(_ film: String, _ edit: (inout Recipe) -> Void = { _ in }) -> Recipe {
            var r = Recipe(filmID: film).applyingNativeTexture(filmID: film)
            edit(&r)
            return r
        }
        func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        func stroke(_ n: Int, _ mode: DodgeBurnMode, from a: CGPoint, to b: CGPoint, size: Double, range: DodgeBurnRange,
                    protect: Bool, luma: LumaRange? = nil) -> DodgeBurnStroke {
            let points = (0...12).map { i -> StrokePoint in
                let t = Double(i) / 12
                return StrokePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + 0.03 * sin(t * .pi * 2), pressure: 0.7 + 0.3 * t)
            }
            return DodgeBurnStroke(id: uuid(n), mode: mode, points: points, size: size, feather: 0.6, flow: 0.6, strength: 0.8,
                                   range: range, protectTones: protect, lumaRange: luma, hidden: false)
        }
        func dodgeBurn(protect: Bool, luma: LumaRange?) -> DodgeBurnSettings {
            DodgeBurnSettings(strokes: [
                stroke(1, .dodge, from: CGPoint(x: 0.2, y: 0.35), to: CGPoint(x: 0.5, y: 0.45), size: 0.18, range: .shadows, protect: protect, luma: luma),
                stroke(2, .burn, from: CGPoint(x: 0.55, y: 0.7), to: CGPoint(x: 0.85, y: 0.55), size: 0.2, range: .highlights, protect: protect, luma: luma),
            ])
        }
        let cn = stocks.colourNegative, mono = stocks.mono, mp = stocks.motionPicture
        var s: [Spec] = []

        // Every film family: its first stock, the default recipe, grain on.
        for family in FilmFamily.displayOrder {
            var stages: [Stage] = [.preview]
            if family == .colorNegative { stages = [.preview, .frame, .export, .proxy] }
            if family == .blackAndWhite { stages = [.preview, .export] }
            s.append(Spec(name: "family-\(family.rawValue)", recipe: look(stocks.byFamily[family]!), stages: stages))
        }

        // Film effects.
        s.append(Spec(name: "halation-strong", recipe: look(cn) { $0.halationAmount = 1; $0.halationRadius = 0.8 }, stages: [.preview, .frame, .export]))
        s.append(Spec(name: "halation-remjet-removed", recipe: look(mp) { $0.remJetRemoved = true; $0.halationAmount = 1 }))
        s.append(Spec(name: "bloom-strong", recipe: look(cn) { $0.bloomAmount = 1 }))
        s.append(Spec(name: "grain-strong", recipe: look(cn) { $0.grainAmount = 1; $0.grainSize = 0.8 }, stages: [.preview, .frame, .export]))
        s.append(Spec(name: "grain-fine-mono", recipe: look(mono) { $0.grainAmount = 0.8; $0.grainSize = 0.2 }))
        s.append(Spec(name: "reciprocity-compensated-30s", recipe: look(cn) { $0.exposureTime = 30 }))
        s.append(Spec(name: "reciprocity-uncompensated-8s", recipe: look(cn) { $0.exposureTime = 8; $0.reciprocity = .uncompensated; $0.reciprocityStrength = 1.5 }))
        s.append(Spec(name: "push-plus1", recipe: look(cn) { $0.push = 1 }))
        s.append(Spec(name: "pull-minus1", recipe: look(cn) { $0.push = -1 }))
        s.append(Spec(name: "scan-frontier", recipe: look(cn) { $0.scanProfile = .frontier }, stages: [.preview, .export]))
        s.append(Spec(name: "scan-noritsu", recipe: look(cn) { $0.scanProfile = .noritsu }))
        s.append(Spec(name: "paper-color", recipe: look(cn) { $0.paper = .colorPaper }))
        s.append(Spec(name: "paper-cinema-print", recipe: look(mp) { $0.paper = .cinemaPrint }))
        for toning in [Toning.selenium, .sepia, .cyanotype, .copper] {
            s.append(Spec(name: "toning-\(toning.rawValue)", recipe: look(mono) { $0.toning = toning; $0.toningStrength = 0.8 },
                          stages: toning == .sepia ? [.preview, .export] : [.preview]))
        }

        // Geometry, local and global adjustments.
        let crop = CropSettings(rect: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8), straighten: 6, rotate90: 1, flipH: true, aspect: "2:3")
        s.append(Spec(name: "crop-rotate-straighten-aspect-flip", recipe: look(cn) { $0.crop = crop }, stages: [.preview, .frame, .export, .proxy]))
        s.append(Spec(name: "dodge-burn-protect-tones", recipe: look(cn) { $0.dodgeBurn = dodgeBurn(protect: true, luma: nil) }, stages: [.preview, .frame, .export]))
        s.append(Spec(name: "dodge-burn-no-protect", recipe: look(cn) { $0.dodgeBurn = dodgeBurn(protect: false, luma: nil) }))
        s.append(Spec(name: "dodge-burn-luma-range", recipe: look(cn) { $0.dodgeBurn = dodgeBurn(protect: true, luma: LumaRange(low: 0.25, high: 0.8, softness: 0.12)) }))
        s.append(Spec(name: "dodge-burn-no-protect-luma-range", recipe: look(cn) { $0.dodgeBurn = dodgeBurn(protect: false, luma: LumaRange(low: 0.1, high: 0.6, softness: 0.05)) }))
        s.append(Spec(name: "curves-mixer", recipe: look(cn) {
            $0.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)]
            $0.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.56), CurvePoint(x: 1, y: 1)]
            $0.curves.luminance = [CurvePoint(x: 0, y: 0.03), CurvePoint(x: 1, y: 0.97)]
            $0.colorMixer.orange = ColorAdjust(hue: 0.3, saturation: 0.25, luminance: 0.1)
            $0.colorMixer.blue = ColorAdjust(hue: -0.2, saturation: -0.2, luminance: -0.1)
            $0.colorMixer.green = ColorAdjust(hue: 0.1, saturation: 0.3, luminance: -0.15)
        }, stages: [.preview, .export]))
        s.append(Spec(name: "tone-controls", recipe: look(cn) {
            $0.highlights = -0.4; $0.shadows = 0.4; $0.whites = 0.2; $0.blacks = -0.2
            $0.clarity = 0.35; $0.texture = 0.3; $0.vibrance = 0.3
        }, stages: [.preview, .export]))
        s.append(Spec(name: "basic-sliders", recipe: look(cn) {
            $0.exposure = 0.5; $0.contrast = 0.2; $0.saturation = -0.2; $0.warmth = 0.3; $0.tint = -0.1
        }))
        s.append(Spec(name: "vignette-border", recipe: look(cn) { $0.vignetteAmount = 0.5; $0.borderEnabled = true; $0.borderWidth = 0.05 },
                      stages: [.preview, .frame, .export]))
        s.append(Spec(name: "legacy-pipeline-1", recipe: {
            var r = Recipe(filmID: cn, grainAmount: 0.4, halationAmount: 0.3, bloomAmount: 0.2, vignetteAmount: 0.2, pipeline: Recipe.legacyPipeline)
            r.contrast = 0.1
            return r
        }(), stages: [.preview, .export]))
        s.append(Spec(name: "strength-half", recipe: look(cn) { $0.strength = 0.5 }))
        s.append(Spec(name: "no-film-original", recipe: Recipe(), stages: [.preview, .frame]))
        s.append(Spec(name: "no-film-sliders", recipe: Recipe(exposure: 0.4, contrast: 0.25, saturation: 0.3, warmth: -0.2, vignetteAmount: 0.3)))
        s.append(Spec(name: "kitchen-sink", recipe: look(cn) {
            $0.crop = crop; $0.dodgeBurn = dodgeBurn(protect: true, luma: nil)
            $0.colorMixer.red = ColorAdjust(hue: 0.1, saturation: 0.2, luminance: 0); $0.highlights = -0.3; $0.clarity = 0.2
            $0.halationAmount = 0.8; $0.bloomAmount = 0.6; $0.vignetteAmount = 0.3; $0.borderEnabled = true; $0.push = 1
        }))

        // RAW, through the app's develop path. Default settings, and non-default (white balance, boost, noise reduction ...).
        let customRaw = RawSettings(temperature: 4800, tint: 12, boostAmount: 0.4, shadowBias: 0.3,
                                    luminanceNoiseReductionAmount: 0.5, colorNoiseReductionAmount: 0.6, sharpnessAmount: 0.4)
        s.append(Spec(name: "raw-default-film", recipe: look(cn), source: .raw, stages: [.preview, .frame, .export, .proxy]))
        s.append(Spec(name: "raw-custom-film", recipe: look(cn) { $0.raw = customRaw }, source: .raw, stages: [.preview, .export]))
        s.append(Spec(name: "raw-default-no-film", recipe: Recipe(), source: .raw))
        s.append(Spec(name: "raw-draft-default-film", recipe: look(cn), source: .raw, rawDraft: true))
        s.append(Spec(name: "raw-custom-mono-toned", recipe: look(mono) { $0.raw = RawSettings(temperature: 6500, boostAmount: 0.2, colorNoiseReductionAmount: 0.3); $0.toning = .selenium }, source: .raw))

        // Other source kinds.
        s.append(Spec(name: "heic-film", recipe: look(cn), source: .heic, stages: [.preview, .export]))
        s.append(Spec(name: "jpeg-orientation6-film", recipe: look(cn), source: .tagged))
        return s
    }

    /// Film-strip card thumbnails: `nil` (the untouched picture) and the first stock of every family.
    static func thumbnailIDs(_ stocks: Stocks) -> [String?] {
        [nil] + FilmFamily.displayOrder.map { Optional(stocks.byFamily[$0]!) }
    }

    /// Cases whose export is written to JPEG, HEIC and TIFF: pixels read back and the metadata dictionary compared.
    static let exportFileCases: [(name: String, formats: [UTType])] = [
        ("jpeg-exif-orientation6-film", [.jpeg, .heic, .tiff]),
        ("raw-custom-film", [.jpeg, .heic, .tiff]),
    ]

    // MARK: Entry point

    static func run(mode: String, filmsPath: String, refPath: String?, outPath: String, fixtures: String, only: String?) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let run = try GoldenRun(filmsPath: filmsPath, fixtures: fixtures, only: only)
            switch mode {
            case "record":
                return try run.record(into: URL(fileURLWithPath: outPath, isDirectory: true))
            case "compare":
                guard let refPath else { throw GoldenError("--golden compare needs --ref <dir>") }
                return try run.compare(ref: URL(fileURLWithPath: refPath, isDirectory: true), out: URL(fileURLWithPath: outPath, isDirectory: true))
            default:
                throw GoldenError("--golden takes record or compare")
            }
        } catch {
            FileHandle.standardError.write(Data("mira-sheet --golden: \(error)\n".utf8))
            return 2
        }
    }
}

struct GoldenError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

// MARK: - Manifest

struct GoldenEntry: Codable {
    var id: String
    var kind: String      // "image" or "text"
    var stage: String
    var file: String
    var source: String
    var path: String
    var width: Int?
    var height: Int?
    var bits: Int?
    var colorSpace: String?
    var recipe: String?
}

struct GoldenManifest: Codable {
    var version = 1
    var machine: String
    var entries: [GoldenEntry]
}

// MARK: - One run

enum GoldenArtifact {
    case image(GoldenPixels, space: CGColorSpace)
    case text(String)
}

struct GoldenItem {
    var id: String
    var stage: String
    var source: String
    var path: String
    var recipe: Recipe?
    var tolerance: Golden.Tolerance
    var produce: () throws -> GoldenArtifact
}

/// Collects thumbnails delivered from the renderer's worker threads.
final class GoldenThumbBox: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    func add(_ id: String?, _ image: CGImage) { lock.lock(); images[id ?? "original"] = image; lock.unlock() }
    var all: [String: CGImage] { lock.lock(); defer { lock.unlock() }; return images }
}

final class GoldenRun {
    let library: FilmLibrary
    let stocks: Golden.Stocks
    let fixtures: URL
    let only: String?
    let context = Renderer.sharedContext
    let canvas = Bench.canvasPixels
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The directory that holds the HEIC and the orientation-tagged JPEG (`<ref>/sources`).
    var sourcesDirectory: URL
    private var decoded: [Golden.Src: CIImage] = [:]
    private var loaded: [Golden.Src: CIImage] = [:]
    private var rawDevelop: RawDevelop?
    private var thumbnails: [String: CGImage]?
    private var exportFiles: [String: (pixels: GoldenPixels, space: CGColorSpace, meta: String)] = [:]
    private var tempDirectory: URL

    init(filmsPath: String, fixtures: String, only: String?) throws {
        library = try FilmLibrary(directory: URL(fileURLWithPath: filmsPath, isDirectory: true))
        stocks = try Golden.Stocks(library: library)
        self.fixtures = URL(fileURLWithPath: fixtures, isDirectory: true)
        self.only = only
        sourcesDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tempDirectory) }

    // MARK: Sources

    func url(_ src: Golden.Src) -> URL {
        switch src {
        case .sample: fixtures.appendingPathComponent("sample.jpg")
        case .raw: fixtures.appendingPathComponent("raw/iphone-xs.dng")
        case .tagged: sourcesDirectory.appendingPathComponent("sample-orientation6.jpg")
        case .heic: sourcesDirectory.appendingPathComponent("sample.heic")
        }
    }

    /// The generated sources: a HEIC of sample.jpg and a JPEG of it that carries EXIF and orientation 6.
    /// Written once at record time into `<ref>/sources`; compare reads them from there.
    func writeGeneratedSources(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourcesDirectory = directory
        let sample = url(.sample)
        guard let src = CGImageSourceCreateWithURL(sample as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw GoldenError("cannot read \(sample.path)") }
        func write(_ type: UTType, to file: URL, _ properties: [CFString: Any]) throws {
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else {
                throw GoldenError("cannot create \(file.path)")
            }
            CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw GoldenError("cannot write \(file.path)") }
        }
        try write(.heic, to: url(.heic), [kCGImageDestinationLossyCompressionQuality: 0.9])
        try write(.jpeg, to: url(.tagged), [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Mira Golden", kCGImagePropertyTIFFModel: "Reference 1",
                                             kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFSoftware: "mira-sheet"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.5, kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifISOSpeedRatings: [400],
                                             kCGImagePropertyExifDateTimeOriginal: "2025:06:01 10:30:00",
                                             kCGImagePropertyExifFocalLength: 35, kCGImagePropertyExifLensModel: "Golden 35mm f/2.8"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "golden render source"],
        ])
    }

    /// The preview-path source of a plain file (the Mac editor decodes it into memory).
    func decodedSource(_ src: Golden.Src) throws -> CIImage {
        if let hit = decoded[src] { return hit }
        guard let image = ImageSource.loadDecoded(url: url(src)) else { throw GoldenError("cannot load \(url(src).path)") }
        decoded[src] = image
        return image
    }

    /// The export- and iOS-path source (lazy `ImageSource.load`).
    func loadedSource(_ src: Golden.Src) throws -> CIImage {
        if let hit = loaded[src] { return hit }
        guard let image = ImageSource.load(url: url(src)) else { throw GoldenError("cannot load \(url(src).path)") }
        loaded[src] = image
        return image
    }

    func develop() throws -> RawDevelop {
        if let rawDevelop { return rawDevelop }
        guard let d = RawDevelop(url: url(.raw), orientation: nil) else { throw GoldenError("cannot open RAW \(url(.raw).path)") }
        rawDevelop = d
        return d
    }

    /// The source the preview path grades for `spec`.
    func previewSource(_ spec: Golden.Spec) throws -> CIImage {
        guard spec.source == .raw else { return try decodedSource(spec.source) }
        let filmApplied = spec.recipe.filmID != nil
        if spec.rawDraft {
            // The first editable frame: draft decode at preview size, as the editors open a RAW photo.
            guard let frame = RawOpener.openDraft(url: url(.raw), orientation: nil, settings: spec.recipe.raw,
                                                  filmApplied: filmApplied, cacheKey: nil) else { throw GoldenError("RAW draft failed") }
            return frame.source.image
        }
        // The full-quality preview decode that replaces the draft (draft mode off, preview size).
        guard let refined = RawOpener.refine(develop: try develop(), settings: spec.recipe.raw, filmApplied: filmApplied)
        else { throw GoldenError("RAW refine failed") }
        return refined.image
    }

    /// The source export grades for `spec`, and the colour space it writes in.
    func exportSource(_ spec: Golden.Spec) throws -> (CIImage, CGColorSpace) {
        if spec.source == .raw {
            // `EditorModel.exportSource`: a fresh full-quality, full-size develop of the recipe.
            guard let image = ImageSource.developedSource(url: url(.raw), orientation: nil, recipe: spec.recipe, draft: false)
            else { throw GoldenError("RAW develop failed") }
            return (image, ImageSource.outputColorSpace(url: url(.raw), image: image))
        }
        let image = try loadedSource(spec.source)
        return (image, ImageSource.outputColorSpace(url: url(spec.source), image: image))
    }

    // MARK: Stages

    func renderer() -> Renderer { Renderer(library: library) }

    func engine(for source: CIImage) -> PreviewEngine {
        let e = PreviewEngine(renderer: renderer(), context: context)
        e.setSource(source)
        return e
    }

    func previewArtifact(_ spec: Golden.Spec) throws -> GoldenArtifact {
        let source = try previewSource(spec)
        let engine = engine(for: source)
        guard let base = engine.previewBase(crop: spec.recipe.crop, canvas: canvas), let size = engine.sourceSize else {
            throw GoldenError("no preview base for \(spec.name)")
        }
        // PreviewEngine.render, with a 16-bit hand-off instead of the BGRA8 frame.
        let whole = CropGeometry.outputExtent(for: spec.recipe.crop, imageExtent: CGRect(origin: .zero, size: size)).size
        let scale = whole.width > 0 ? min(1, base.extent.width / whole.width) : 1
        let graded = engine.renderer.withPreviewScale(scale)
            .grade(spec.recipe, cropped: base, sourceSize: size, maskOverlay: false,
                   sourceHeadroom: source.miraHeadroom, sourceExposureTime: engine.exposureTime)
        guard let px = GoldenPixels.render(graded, context: context, space: srgb, bits: 16) else { throw GoldenError("render failed \(spec.name)") }
        return .image(px, space: srgb)
    }

    func frameArtifact(_ spec: Golden.Spec) throws -> GoldenArtifact {
        let engine = engine(for: try previewSource(spec))
        guard let frame = engine.render(spec.recipe, canvas: canvas), let cg = frame.cgImage(context: context),
              let px = GoldenPixels(cgImage: cg, bits: 8) else { throw GoldenError("no frame for \(spec.name)") }
        return .image(px, space: srgb)
    }

    func exportArtifact(_ spec: Golden.Spec) throws -> GoldenArtifact {
        let (source, space) = try exportSource(spec)
        let out = renderer().apply(spec.recipe, to: source)
        guard let cg = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: space),
              let px = GoldenPixels(cgImage: cg, bits: 8) else { throw GoldenError("export render failed \(spec.name)") }
        return .image(px, space: space)
    }

    /// The iPhone 16 Pro native screen box (portrait), the box `LivePreview` sizes its proxy for.
    static let iPhoneBox = CGSize(width: 1206, height: 2622)

    func proxyArtifact(_ spec: Golden.Spec) throws -> GoldenArtifact {
        let source: CIImage
        if spec.source == .raw {
            // The iOS editor opens a RAW photo with `RawOpener.openDraft`.
            guard let frame = RawOpener.openDraft(url: url(.raw), orientation: nil, settings: spec.recipe.raw,
                                                  filmApplied: spec.recipe.filmID != nil, cacheKey: nil) else { throw GoldenError("RAW draft failed") }
            source = frame.source.image
        } else {
            source = try loadedSource(spec.source)
        }
        // LivePreview.proxyLongSide(zoom: 1).
        let e = source.extent, box = Self.iPhoneBox
        let longest = max(e.width, e.height)
        let fit = min(box.width / e.width, box.height / e.height)
        let wanted = min(longest, (longest * fit).rounded(.up))
        let renderer = renderer()
        let proxy = PreviewProxy.make(from: source, renderer: renderer, context: context, wanted: wanted)
        // LivePreview.gradedImage.
        let scale = min(1, proxy.extent.width / max(e.width, 1))
        let graded = renderer.withPreviewScale(scale).apply(spec.recipe, to: proxy)
        guard let px = GoldenPixels.render(graded, context: context, space: srgb, bits: 16) else { throw GoldenError("proxy render failed \(spec.name)") }
        return .image(px, space: srgb)
    }

    /// All film-strip tiles at once (one base, the app's worker pool), rendered on first use.
    func thumbnail(_ id: String?) throws -> GoldenArtifact {
        if thumbnails == nil {
            let engine = engine(for: try decodedSource(.sample))
            let box = GoldenThumbBox()
            engine.renderThumbnails(ids: Golden.thumbnailIDs(stocks), crop: .identity, longSide: 256, diskCache: nil) { id, cg in box.add(id, cg) }
            thumbnails = box.all
        }
        guard let cg = thumbnails?[id ?? "original"], let px = GoldenPixels(cgImage: cg, bits: 8) else { throw GoldenError("no thumbnail for \(id ?? "original")") }
        return .image(px, space: srgb)
    }

    /// `Renderer.export` to `type`; the file is read back for its pixels and its metadata.
    func exportFile(_ name: String, _ type: UTType) throws -> (pixels: GoldenPixels, space: CGColorSpace, meta: String) {
        let key = "\(name).\(type.preferredFilenameExtension ?? "bin")"
        if let hit = exportFiles[key] { return hit }
        let file = tempDirectory.appendingPathComponent(key)
        let renderer = renderer()
        switch name {
        case "raw-custom-film":
            let spec = specs().first { $0.name == name }!
            let (image, space) = try exportSource(spec)
            try renderer.export(spec.recipe, source: image, metadataFrom: url(.raw), outputURL: file, type: type, quality: 0.9, colorSpace: space)
        default:
            let spec = specs().first { $0.name == "jpeg-orientation6-film" }!
            try renderer.export(spec.recipe, inputURL: url(.tagged), outputURL: file, type: type, quality: 0.9)
        }
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let px = GoldenPixels(cgImage: cg, bits: 8),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { throw GoldenError("cannot read back \(file.lastPathComponent)") }
        var lines: [String] = []
        Self.flatten(props, prefix: "", into: &lines)
        // The file size depends on the encoder's bytes, not on metadata; the decoded pixels are compared separately.
        lines.removeAll { $0.hasPrefix("FileSize") }
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? srgb
        let result = (px, space, lines.sorted().joined(separator: "\n") + "\n")
        exportFiles[key] = result
        return result
    }

    static func flatten(_ value: Any, prefix: String, into lines: inout [String]) {
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() { flatten(dict[key]!, prefix: prefix.isEmpty ? key : prefix + "." + key, into: &lines) }
        } else if let array = value as? [Any] {
            lines.append("\(prefix) = [" + array.map { "\($0)" }.joined(separator: ", ") + "]")
        } else if let data = value as? Data {
            lines.append("\(prefix) = <\(data.count) bytes>")
        } else {
            lines.append("\(prefix) = \(value)")
        }
    }

    /// The bytes the app persists for `recipe`, as one text.
    func codecText(_ spec: Golden.Spec) throws -> String {
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        let recipe = spec.recipe
        var out = "== Recipe.encoded() ==\n" + text(try recipe.encoded()) + "\n"
        let adjustment = try MiraAdjustment.adjustmentData(for: recipe)
        out += "== MiraAdjustment.adjustmentData ==\n\(adjustment.formatIdentifier) v\(adjustment.formatVersion)\n" + text(adjustment.data) + "\n"
        let rawBase = try MiraAdjustment.adjustmentData(for: recipe, rawBase: true)
        out += "== MiraAdjustment.adjustmentData(rawBase) ==\n\(rawBase.formatIdentifier) v\(rawBase.formatVersion)\n" + text(rawBase.data) + "\n"
        let filmName = recipe.filmID.flatMap { library.film(id: $0)?.displayName }
        let preset = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!, nickname: "Golden", recipe: recipe, filmName: filmName,
                            created: Date(timeIntervalSince1970: 1_700_000_000))
        let exported = Date(timeIntervalSince1970: 1_700_000_100)
        let presetBytes = try PresetFile.encode(preset, appVersion: "0.0.0", exported: exported)
        out += "== PresetFile.encode ==\n" + text(presetBytes) + "\n"
        // Round trips: what the app reads back from its own files encodes to the same bytes.
        let decoded = MiraAdjustment.decode(formatIdentifier: adjustment.formatIdentifier, formatVersion: adjustment.formatVersion, data: adjustment.data)
        let adjustmentStable = try decoded.map { try MiraAdjustment.encode($0) == adjustment.data } ?? false
        let presetBack = try PresetFile.decode(presetBytes)
        let presetStable = try PresetFile.encode(presetBack, appVersion: "0.0.0", exported: exported) == presetBytes
        out += "== round trips ==\nadjustment data re-encodes identically: \(adjustmentStable)\npreset file re-encodes identically: \(presetStable)\n"
        return out
    }

    // MARK: Items

    func specs() -> [Golden.Spec] { Golden.specs(stocks) }

    /// Every artifact, in table order.
    func items() -> [GoldenItem] {
        var items: [GoldenItem] = []
        func tolerance(_ id: String) -> Golden.Tolerance { Golden.tolerances[id] ?? Golden.defaultTolerance }
        for spec in specs() {
            let sourceName = spec.source.rawValue
            for stage in spec.stages {
                let id = "\(spec.name)/\(stage.rawValue)"
                let path: String
                let produce: () throws -> GoldenArtifact
                switch stage {
                case .preview:
                    path = spec.rawDraft ? "RawOpener.openDraft -> PreviewEngine.previewBase + Renderer.grade -> 16-bit sRGB (canvas 1500x1000)"
                        : "PreviewEngine.previewBase + Renderer.grade -> 16-bit sRGB (canvas 1500x1000)" + (spec.source == .raw ? "; source RawOpener.refine" : "; source ImageSource.loadDecoded")
                    produce = { [self] in try previewArtifact(spec) }
                case .frame:
                    path = "PreviewEngine.render -> BGRA8 frame (canvas 1500x1000)"
                    produce = { [self] in try frameArtifact(spec) }
                case .export:
                    path = "Renderer.apply + createCGImage RGBA8 at native size" + (spec.source == .raw ? "; source ImageSource.developedSource(draft: false)" : "; source ImageSource.load")
                    produce = { [self] in try exportArtifact(spec) }
                case .proxy:
                    path = "PreviewProxy.make (iPhone 16 Pro box 1206x2622) + Renderer.apply -> 16-bit sRGB"
                    produce = { [self] in try proxyArtifact(spec) }
                }
                items.append(GoldenItem(id: id, stage: stage.rawValue, source: sourceName, path: path, recipe: spec.recipe,
                                        tolerance: tolerance(id), produce: produce))
            }
        }
        for tile in Golden.thumbnailIDs(stocks) {
            let id = "thumb-\(tile ?? "original")/thumb"
            items.append(GoldenItem(id: id, stage: "thumb", source: "sample", path: "PreviewEngine.renderThumbnails (longSide 256, no disk cache) -> RGBA8 sRGB",
                                    recipe: nil, tolerance: tolerance(id), produce: { [self] in try thumbnail(tile) }))
        }
        for (name, formats) in Golden.exportFileCases {
            for type in formats {
                let ext = type.preferredFilenameExtension ?? "bin"
                let source = name.hasPrefix("raw") ? "raw" : "tagged"
                let recipe = specs().first { $0.name == (name.hasPrefix("raw") ? name : "jpeg-orientation6-film") }?.recipe
                let pixelsID = "file-\(name).\(ext)/pixels", metaID = "file-\(name).\(ext)/metadata"
                items.append(GoldenItem(id: pixelsID, stage: "file", source: source, path: "Renderer.export -> \(ext), decoded back to 8-bit",
                                        recipe: recipe, tolerance: tolerance(pixelsID), produce: { [self] in
                    let r = try exportFile(name, type); return .image(r.pixels, space: r.space)
                }))
                items.append(GoldenItem(id: metaID, stage: "file", source: source, path: "Renderer.export -> \(ext), CGImageSourceCopyPropertiesAtIndex",
                                        recipe: recipe, tolerance: tolerance(metaID), produce: { [self] in .text(try exportFile(name, type).meta) }))
            }
        }
        for spec in specs() {
            let id = "codec-\(spec.name)/codec"
            items.append(GoldenItem(id: id, stage: "codec", source: spec.source.rawValue,
                                    path: "Recipe.encoded, MiraAdjustment.adjustmentData (+rawBase), PresetFile.encode, round trips",
                                    recipe: spec.recipe, tolerance: tolerance(id), produce: { [self] in .text(try codecText(spec)) }))
        }
        if let only { items = items.filter { $0.id.contains(only) } }
        return items
    }

    // MARK: Record

    static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

    static func fileName(_ id: String, text: Bool) -> String {
        id.replacingOccurrences(of: "/", with: ".") + (text ? ".txt" : ".png")
    }

    func machine() -> String {
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "no GPU"
        return "\(ProcessInfo.processInfo.operatingSystemVersionString); \(gpu)"
    }

    func record(into dir: URL) throws -> Int32 {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("text"), withIntermediateDirectories: true)
        try writeGeneratedSources(into: dir.appendingPathComponent("sources"))
        let manifestURL = dir.appendingPathComponent("manifest.json")
        // `--only` records into an existing reference: keep the entries it does not touch.
        var entries: [GoldenEntry] = []
        if only != nil, let data = try? Data(contentsOf: manifestURL), let old = try? JSONDecoder().decode(GoldenManifest.self, from: data) {
            entries = old.entries
        }
        var failed = 0
        let list = items()
        for (n, item) in list.enumerated() {
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                var entry = GoldenEntry(id: item.id, kind: "image", stage: item.stage, file: "", source: item.source, path: item.path,
                                        recipe: try item.recipe.map { String(decoding: try $0.encoded(), as: UTF8.self) })
                switch try item.produce() {
                case .image(let px, let space):
                    entry.file = "images/" + Self.fileName(item.id, text: false)
                    guard px.writePNG(to: dir.appendingPathComponent(entry.file), space: space) else { throw GoldenError("cannot write \(entry.file)") }
                    entry.width = px.width; entry.height = px.height; entry.bits = px.bits
                    entry.colorSpace = (space.name as String?) ?? "unnamed"
                case .text(let text):
                    entry.kind = "text"
                    entry.file = "text/" + Self.fileName(item.id, text: true)
                    try text.write(to: dir.appendingPathComponent(entry.file), atomically: true, encoding: .utf8)
                }
                entries.removeAll { $0.id == item.id }
                entries.append(entry)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                let what = entry.kind == "image" ? "\(entry.width!)x\(entry.height!) \(entry.bits!)-bit" : "text"
                print("[\(n + 1)/\(list.count)] recorded \(Self.pad(item.id, 56)) \(Self.pad(what, 16)) " + String(format: "%6.0f ms", ms))
            } catch {
                failed += 1
                print("[\(n + 1)/\(list.count)] FAILED \(item.id): \(error)")
            }
        }
        entries.sort { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(GoldenManifest(machine: machine(), entries: entries)).write(to: manifestURL)
        print("recorded \(list.count - failed) of \(list.count) artifacts into \(dir.path) (\(entries.count) in the manifest)")
        return failed == 0 ? 0 : 1
    }

    // MARK: Compare

    func compare(ref: URL, out: URL) throws -> Int32 {
        guard let data = try? Data(contentsOf: ref.appendingPathComponent("manifest.json")) else {
            throw GoldenError("no manifest.json in \(ref.path): record first")
        }
        let manifest = try JSONDecoder().decode(GoldenManifest.self, from: data)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        sourcesDirectory = ref.appendingPathComponent("sources")
        let byID = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        print("reference recorded on: \(manifest.machine)")
        print("this machine:          \(machine())")
        print("tolerance (8-bit levels): mean <= \(Golden.defaultTolerance.mean), max <= \(Golden.defaultTolerance.max); text artifacts must be identical")
        var failures = 0, passes = 0
        var seen = Set<String>()
        let list = items()
        for item in list {
            seen.insert(item.id)
            guard let entry = byID[item.id] else {
                print("FAIL  \(item.id)  missing in the reference")
                failures += 1
                continue
            }
            do {
                let artifact = try item.produce()
                switch artifact {
                case .image(let px, let space):
                    guard entry.kind == "image", let bits = entry.bits,
                          let reference = GoldenPixels.readPNG(at: ref.appendingPathComponent(entry.file), bits: bits) else {
                        print("FAIL  \(item.id)  reference image unreadable or not an image")
                        failures += 1; continue
                    }
                    var problems: [String] = []
                    if let name = entry.colorSpace, name != ((space.name as String?) ?? "unnamed") {
                        problems.append("colour space \(name) -> \((space.name as String?) ?? "unnamed")")
                    }
                    let diff = GoldenDiff.between(reference: reference, current: px)
                    if diff.sizeMismatch {
                        problems.append("size/depth \(reference.width)x\(reference.height) \(reference.bits)-bit -> \(px.width)x\(px.height) \(px.bits)-bit")
                        print("FAIL  \(item.id)  \(problems.joined(separator: "; "))")
                        failures += 1; continue
                    }
                    let tol = item.tolerance
                    if diff.mean > tol.mean { problems.append("mean above \(tol.mean)") }
                    if diff.max > tol.max { problems.append("max above \(tol.max)") }
                    let line = (problems.isEmpty ? "ok    " : "FAIL  ") + Self.pad(item.id, 56)
                        + String(format: " mean %.4f  p99.9 %.2f  max %.2f  >1: %d", diff.mean, diff.p999, diff.max, diff.over1)
                    print(line + (problems.isEmpty ? "" : "  (" + problems.joined(separator: "; ") + ")"))
                    if problems.isEmpty { passes += 1 } else {
                        failures += 1
                        let stem = Self.fileName(item.id, text: false).replacingOccurrences(of: ".png", with: "")
                        _ = diff.diffImage(width: px.width, height: px.height, unit: px.unit)
                            .writePNG(to: out.appendingPathComponent(stem + ".diff.png"), space: srgb)
                        _ = px.writePNG(to: out.appendingPathComponent(stem + ".current.png"), space: space)
                    }
                case .text(let text):
                    guard entry.kind == "text", let expected = try? String(contentsOf: ref.appendingPathComponent(entry.file), encoding: .utf8) else {
                        print("FAIL  \(item.id)  reference text unreadable or not text")
                        failures += 1; continue
                    }
                    if text == expected {
                        print("ok    \(item.id)  identical")
                        passes += 1
                    } else {
                        failures += 1
                        print("FAIL  \(item.id)  text differs")
                        let a = expected.split(separator: "\n", omittingEmptySubsequences: false)
                        let b = text.split(separator: "\n", omittingEmptySubsequences: false)
                        var shown = 0
                        for i in 0..<max(a.count, b.count) where shown < 6 {
                            let l = i < a.count ? String(a[i]) : "<none>", r = i < b.count ? String(b[i]) : "<none>"
                            if l != r { print("        ref: \(l.prefix(200))\n        now: \(r.prefix(200))"); shown += 1 }
                        }
                        let stem = Self.fileName(item.id, text: true)
                        try? text.write(to: out.appendingPathComponent(stem + ".current"), atomically: true, encoding: .utf8)
                    }
                }
            } catch {
                print("FAIL  \(item.id)  \(error)")
                failures += 1
            }
        }
        if only == nil {
            for entry in manifest.entries where !seen.contains(entry.id) {
                print("FAIL  \(entry.id)  in the reference but no longer produced")
                failures += 1
            }
        }
        print("golden compare: \(passes) ok, \(failures) failed, \(list.count) artifacts")
        return failures == 0 ? 0 : 1
    }
}
