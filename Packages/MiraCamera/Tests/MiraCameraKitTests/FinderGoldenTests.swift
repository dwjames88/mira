import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MiraCore
import Testing
import UniformTypeIdentifiers
@testable import MiraCameraKit

// Golden renders of the finder's grading graph (Round 3, phase 0). Opt-in: skipped unless MIRA_GOLDEN_DIR is set.
//
//   record:  MIRA_GOLDEN_DIR=<golden>/ref MIRA_GOLDEN_RECORD=1 swift test --no-parallel --filter FinderGoldenTests
//   compare: MIRA_GOLDEN_DIR=<golden>/ref swift test --no-parallel --filter FinderGoldenTests
//
// References live in <MIRA_GOLDEN_DIR>/finder as 16-bit PNGs. Films come from <repo>/Films (override with MIRA_FILMS_DIR),
// the picture from <repo>/Fixtures/sample.jpg.
//
// `FinderRenderer` itself is `#if os(iOS)` (CAMetalLayer / UIKit frames), so it cannot run in a macOS package test. What it
// does to a frame is rebuilt here from the same public pieces, step for step (FinderRenderer.consume): fit the upright frame
// into the drawable at the quality's render scale, then `Renderer.withPreviewScale(FinderRecipe.previewScale)
// .withGrainSeed(FinderRecipe.grainSeed).withTextureScale(quality.textureScale).apply(FinderRecipe.recipe(...))`. What is not
// covered: the camera frame rotation / aspect crop (`FinderRenderer.upright`), the upscale to the drawable, the Metal drawable.
//
// Tolerance, in 8-bit levels per channel (16-bit units / 257): mean <= 0.05, max <= 2 (same as `mira-sheet --golden`).

@Suite struct FinderGoldenTests {
    static let meanTolerance = 0.05
    static let maxTolerance = 2.0
    /// One finder frame index, so the grain field is the same every run.
    static let frameIndex = 7
    /// A phone-sized drawable and the capture long side of a 12 MP photo.
    static let drawable = CGSize(width: 1170, height: 780)
    static let captureLongSide = 4032.0

    static var goldenDir: URL? {
        ProcessInfo.processInfo.environment["MIRA_GOLDEN_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("finder") }
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The finder levels worth pinning: full, grain off (the ladder's second rung), reduced (render scale 0.75) and half texture.
    static let levels: [(name: String, level: FinderLevel)] = [
        ("full", .full), ("grain-off", .grainOff), ("scale-0.75", .reduced), ("half-texture", .halfTexture),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRA_GOLDEN_DIR"] != nil))
    func finderFramesMatchTheGoldenRenders() throws {
        let dir = try #require(Self.goldenDir)
        let record = ProcessInfo.processInfo.environment["MIRA_GOLDEN_RECORD"] == "1"
        let filmsDir = ProcessInfo.processInfo.environment["MIRA_FILMS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.repoRoot.appendingPathComponent("Films", isDirectory: true)
        let library = try FilmLibrary(directory: filmsDir)
        let film = try #require(library.stocks.first(where: { $0.family == .colorNegative }) ?? library.films.first)
        let sample = Self.repoRoot.appendingPathComponent("Fixtures/sample.jpg")
        let source = try #require(ImageSource.loadDecoded(url: sample))
        var user = Recipe(filmID: film.id).applyingNativeTexture(filmID: film.id)
        user.grainAmount = 0.6
        user.halationAmount = 0.5
        let renderer = Renderer(library: library)
        let context = Renderer.sharedContext
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if record { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        for (name, level) in Self.levels {
            let quality = level.quality()
            // FinderRenderer.consume, from "Fit the upright frame into the target" on.
            let extent = source.extent
            let rs = CGFloat(quality.renderScale)
            let box = CGSize(width: Self.drawable.width * rs, height: Self.drawable.height * rs)
            let s = min(box.width / extent.width, box.height / extent.height)
            let gradedSize = CGSize(width: extent.width * s, height: extent.height * s)
            var scaled = source
            if abs(s - 1) > 1e-4 { scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
            scaled = scaled.withMiraHeadroom(1).withMiraExposureTime(nil)
            let previewScale = FinderRecipe.previewScale(finderLongSide: Double(max(gradedSize.width, gradedSize.height)),
                                                         captureLongSide: Self.captureLongSide)
            let seed = quality.grainLive ? FinderRecipe.grainSeed(frameIndex: Self.frameIndex) : nil
            let picture = renderer.withPreviewScale(CGFloat(previewScale))
                .withGrainSeed(seed)
                .withTextureScale(CGFloat(quality.textureScale))
                .apply(FinderRecipe.recipe(from: user, quality: quality), to: scaled)
            let pixels = try #require(GoldenFrame.render(picture, context: context, space: srgb))
            let file = dir.appendingPathComponent("finder-\(name).png")
            if record {
                try #require(pixels.writePNG(to: file, space: srgb))
                print("finder golden recorded \(file.lastPathComponent) \(pixels.width)x\(pixels.height)")
                continue
            }
            let reference = try #require(GoldenFrame.read(file), "no reference \(file.path): record with MIRA_GOLDEN_RECORD=1")
            #expect(reference.width == pixels.width && reference.height == pixels.height, "\(name): size changed")
            guard reference.width == pixels.width, reference.height == pixels.height else { continue }
            let (mean, max) = GoldenFrame.difference(reference, pixels)
            print(String(format: "finder golden %@: mean %.4f max %.2f levels", name, mean, max))
            #expect(mean <= Self.meanTolerance, "\(name): mean difference \(mean) levels")
            #expect(max <= Self.maxTolerance, "\(name): max difference \(max) levels")
        }
    }
}

/// 16-bit RGB samples of a rendered frame, with PNG read / write and the difference in 8-bit levels.
private struct GoldenFrame {
    var width: Int
    var height: Int
    var samples: [UInt16]

    static func render(_ image: CIImage, context: CIContext, space: CGColorSpace) -> GoldenFrame? {
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty else { return nil }
        let w = Int(e.width.rounded()), h = Int(e.height.rounded())
        var rgba = [UInt16](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &rgba, rowBytes: w * 8, bounds: e, format: .RGBA16, colorSpace: space)
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2] }
        return GoldenFrame(width: w, height: h, samples: rgb)
    }

    func writePNG(to url: URL, space: CGColorSpace) -> Bool {
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (i, s) in samples.enumerated() { bytes[i * 2] = UInt8(s >> 8); bytes[i * 2 + 1] = UInt8(s & 0xFF) }
        let info = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func read(_ url: URL) -> GoldenFrame? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let ok: Bool = raw.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = raw[i * 4]; rgb[i * 3 + 1] = raw[i * 4 + 1]; rgb[i * 3 + 2] = raw[i * 4 + 2] }
        return GoldenFrame(width: w, height: h, samples: rgb)
    }

    /// Mean and max absolute difference per channel, in 8-bit levels (16-bit units / 257).
    static func difference(_ a: GoldenFrame, _ b: GoldenFrame) -> (mean: Double, max: Double) {
        var total = 0.0
        var worst = 0
        for i in 0..<a.samples.count {
            let d = abs(Int(a.samples[i]) - Int(b.samples[i]))
            total += Double(d)
            if d > worst { worst = d }
        }
        return (total / Double(a.samples.count) / 257, Double(worst) / 257)
    }
}
