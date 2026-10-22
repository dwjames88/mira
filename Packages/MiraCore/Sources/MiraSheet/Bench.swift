import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import MiraCore
import UniformTypeIdentifiers

// `mira-sheet --bench`: headless performance harness. Never touches PhotoKit.
//
// a. preview frame time for a slider change at canvas resolution
// b. open a 24 MP JPEG: first displayable preview and full-res source ready
// c. fill all 32 film-strip thumbnails (cold LUT cache, warm disk cache, hot)
// d. full-resolution 24 MP export
// z. zoomed frames (50%, 100%, 200%): only the visible region of the 24 MP picture is rendered

enum Bench {
    static let canvasPixels = CGSize(width: 1500, height: 1000)

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    static func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let t0 = now()
        let value = try body()
        return (value, now() - t0)
    }

    static func stats(_ samples: [Double]) -> (median: Double, p95: Double) {
        let s = samples.sorted()
        guard !s.isEmpty else { return (0, 0) }
        return (s[s.count / 2], s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)])
    }

    static func row(_ label: String, _ values: String) {
        print(label.padding(toLength: 58, withPad: " ", startingAt: 0) + values)
    }

    /// 6000x4000 JPEG: the fixture upscaled with noise added. Cached in `dir`.
    static func synthetic(from fixture: URL, in dir: URL, context: CIContext) throws -> URL {
        let out = dir.appendingPathComponent("synthetic-24mp.jpg")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard var image = CIImage(contentsOf: fixture, options: [.applyOrientationProperty: true]) else {
            throw RendererError.cannotLoad(fixture)
        }
        let target = CGSize(width: 6000, height: 4000)
        let s = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: false)
            .cropped(to: CGRect(origin: .zero, size: target))
        let noise = CIFilter.randomGenerator().outputImage!
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.03, y: -0.03, z: -0.03, w: 1),
            ])
        let noisy = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: image.extent)
        try context.writeJPEGRepresentation(
            of: noisy, to: out, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        return out
    }

    static let effectsRecipe = Recipe(
        filmID: "fuji-velvia-50", grainAmount: 0.4, halationAmount: 0.3, bloomAmount: 0.2, vignetteAmount: 0.3)

    /// The effects recipe plus a colour-mixer move and an S-curve with a red-channel tweak.
    static var gradeRecipe: Recipe {
        var r = effectsRecipe
        r.colorMixer.orange = ColorAdjust(hue: 0.3, saturation: 0.25, luminance: 0.1)
        r.colorMixer.blue = ColorAdjust(hue: -0.2, saturation: -0.2, luminance: -0.1)
        r.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 1)]
        r.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        return r
    }

    static func cropRecipe() -> Recipe {
        var r = effectsRecipe
        r.crop.rect = CropRect(x: 0.15, y: 0.1, w: 0.6, h: 0.7)
        r.crop.straighten = 6
        return r
    }

    static func run(filmsPath: String, fixturePath: String, benchDir: String) throws {
        let dir = URL(fileURLWithPath: benchDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filmsURL = URL(fileURLWithPath: filmsPath, isDirectory: true)
        let lutCache = dir.appendingPathComponent("lut-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: lutCache)

        let context = Renderer.sharedContext
        let jpeg = try synthetic(from: URL(fileURLWithPath: fixturePath), in: dir, context: context)
        let library = try FilmLibrary(directory: filmsURL, cacheDirectory: lutCache)
        _ = try library.film(id: effectsRecipe.filmID!).map { try library.lut(for: $0) }
        let renderer = Renderer(library: library)

        print("mira bench  (\(ProcessInfo.processInfo.processorCount) cores, 6000x4000 JPEG, canvas \(Int(canvasPixels.width))x\(Int(canvasPixels.height)))")
        print("")
        try Legacy.run(renderer: renderer, library: library, context: context, jpeg: jpeg,
                       filmsURL: filmsURL, benchDir: dir)
        try Current.run(renderer: renderer, library: library, context: context, jpeg: jpeg,
                        filmsURL: filmsURL, benchDir: dir)
        if let full = ImageSource.loadDecoded(url: jpeg) {
            try Extra.run(library: library, full: full, filmsURL: filmsURL, benchDir: dir)
        }
    }
}

/// The pipeline as it was before the performance work: a lazy 1600 px Lanczos copy of the full
/// source, rendered to an 8-bit CGImage each frame.
enum Legacy {
    static func run(renderer: Renderer, library: FilmLibrary, context: CIContext, jpeg: URL,
                    filmsURL: URL, benchDir: URL) throws {
        print("== legacy pipeline ==")
        // b. open
        let (source, loadMs) = Bench.time { ImageSource.load(url: jpeg)! }
        let (firstCG, firstMs) = Bench.time { () -> CGImage? in
            let preview = renderer.previewImage(from: source, maxPixelSize: 1600)
            return renderer.render(Recipe(filmID: Bench.effectsRecipe.filmID), input: preview, context: context)
        }
        precondition(firstCG != nil)
        Bench.row("b. open: ImageSource.load (lazy)", String(format: "%8.1f ms", loadMs))
        Bench.row("b. open: first displayable preview (load+first render)", String(format: "%8.1f ms", loadMs + firstMs))

        // Full-res ready: a first render that reads full-resolution pixels (a 256 px window of the
        // photo at 1:1) forces the decode the lazy source defers.
        let freshSource = ImageSource.load(url: jpeg)!
        let (_, readyMs) = Bench.time {
            let e = freshSource.extent
            let window = freshSource.cropped(to: CGRect(x: e.midX - 128, y: e.midY - 128, width: 256, height: 256))
            return context.createCGImage(window, from: window.extent, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        Bench.row("b. open: full-res source ready (load + first 1:1 read)", String(format: "%8.1f ms", loadMs + readyMs))

        let previewSource = renderer.previewImage(from: source, maxPixelSize: 1600)
        // a. preview frames
        for (label, base) in [("a. preview frame, effects", Bench.effectsRecipe), ("a. preview frame, crop+6deg", Bench.cropRecipe())] {
            _ = renderer.render(base, input: previewSource, context: context) // warm-up
            var samples: [Double] = []
            for i in 0..<60 {
                var r = base
                r.exposure = -1 + 2 * Double(i) / 59
                let (_, ms) = Bench.time { renderer.render(r, input: previewSource, context: context) }
                samples.append(ms)
            }
            let s = Bench.stats(samples)
            Bench.row(label, String(format: "median %7.1f ms   p95 %7.1f ms", s.median, s.p95))
        }

        // a'. where the frame time goes (each stage alone, then the sum)
        let film = Bench.effectsRecipe.filmID
        let parts: [(String, Recipe)] = [
            ("film only", Recipe(filmID: film)),
            ("film + exposure/contrast/sat/warmth", Recipe(filmID: film, exposure: 0.3, contrast: 0.2, saturation: 0.2, warmth: 0.2)),
            ("film + grain 0.4", Recipe(filmID: film, grainAmount: 0.4)),
            ("film + halation 0.3", Recipe(filmID: film, halationAmount: 0.3)),
            ("film + bloom 0.2", Recipe(filmID: film, bloomAmount: 0.2)),
            ("film + vignette 0.3", Recipe(filmID: film, vignetteAmount: 0.3)),
        ]
        for (label, base) in parts {
            _ = renderer.render(base, input: previewSource, context: context)
            var samples: [Double] = []
            for i in 0..<30 {
                var r = base
                r.exposure += 0.01 * Double(i % 7)
                let (_, ms) = Bench.time { renderer.render(r, input: previewSource, context: context) }
                samples.append(ms)
            }
            Bench.row("   stage: " + label, String(format: "median %7.1f ms", Bench.stats(samples).median))
        }

        // c. thumbnails
        for (label, mode) in [("c. 32 thumbnails, cold LUT cache", 0), ("c. 32 thumbnails, warm disk LUT cache", 1), ("c. 32 thumbnails, hot (LUTs in memory)", 2)] {
            let cache = benchDir.appendingPathComponent("lut-cache-thumbs", isDirectory: true)
            if mode == 0 { try? FileManager.default.removeItem(at: cache) }
            let lib = mode == 2 ? library : try FilmLibrary(directory: filmsURL, cacheDirectory: cache)
            if mode == 2 { lib.prewarmSync() }
            let r = Renderer(library: lib)
            let ctx = Renderer.makeContext()
            let (_, ms) = Bench.time {
                legacyThumbnails(renderer: r, context: ctx, previewSource: previewSource, films: lib.films)
            }
            Bench.row(label, String(format: "%8.0f ms", ms))
        }

        // d. export
        let out = benchDir.appendingPathComponent("export-legacy.jpg")
        let recipe = Bench.effectsRecipe
        let (_, exportMs) = try Bench.time {
            try renderer.export(recipe, source: source, metadataFrom: jpeg, outputURL: out, type: .jpeg, quality: 0.95)
        }
        Bench.row("d. export 24 MP JPEG (effects recipe)", String(format: "%8.0f ms", exportMs))
        try? FileManager.default.removeItem(at: out)
        print("")
    }

    /// Mirrors EditorModel.startThumbnails: one 160 px source, `ids.count` renders, 4 at a time.
    static func legacyThumbnails(renderer: Renderer, context: CIContext, previewSource: CIImage, films: [Film]) {
        let small = renderer.previewImage(from: previewSource, maxPixelSize: 160)
        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
        let tiny = CIImage(cgImage: cg)
        let ids: [String?] = [nil] + films.map { Optional($0.id) }
        let box = BenchBox(tiny)
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            _ = renderer.render(Recipe(filmID: ids[i]), input: box.value, context: context)
        }
    }
}

final class BenchBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
