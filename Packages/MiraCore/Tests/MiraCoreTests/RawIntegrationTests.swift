import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

/// Real RAW files (CC0, Fixtures/raw, see its README) through RawDevelop, the renderer and export.
/// Every test skips when its file is absent. `MIRA_RAW_DIR` overrides the folder.
enum RawSamples {
    static func url(_ name: String) -> URL? {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MIRA_RAW_DIR"] { dirs.append(URL(fileURLWithPath: env)) }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("Fixtures/raw"))
        for d in dirs {
            let u = d.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static let sony = url("sony-ilce7m3.arw")
    static let iphoneXS = url("iphone-xs.dng")
    static let iphone12Pro = url("iphone-12-pro.dng")

    static func library() throws -> FilmLibrary {
        try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
    }

    /// File orientation (EXIF/TIFF), 1 when absent.
    static func orientation(_ url: URL) -> CGImagePropertyOrientation {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        return CGImagePropertyOrientation(rawValue: (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up
    }

    static func srgb(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
}

private func openDevelop(_ url: URL?) throws -> RawDevelop {
    let url = try #require(url)
    return try #require(RawDevelop(url: url))
}

private func linearSmall(_ develop: RawDevelop, _ settings: RawSettings, film: Bool) throws -> LinearPixels {
    let img = try #require(develop.apply(settings, filmApplied: film, draft: true, scale: 0.1))
    return LinearPixels(img)
}

private func channelMeans(_ p: LinearPixels) -> (r: Double, g: Double, b: Double) {
    var s = (0.0, 0.0, 0.0)
    let n = p.width * p.height
    for i in 0..<n { s.0 += Double(p.rgba[i * 4]); s.1 += Double(p.rgba[i * 4 + 1]); s.2 += Double(p.rgba[i * 4 + 2]) }
    return (s.0 / Double(n), s.1 / Double(n), s.2 / Double(n))
}

private func lumas(_ p: LinearPixels) -> [Double] {
    (0..<(p.width * p.height)).map {
        0.2126 * Double(p.rgba[$0 * 4]) + 0.7152 * Double(p.rgba[$0 * 4 + 1]) + 0.0722 * Double(p.rgba[$0 * 4 + 2])
    }
}

@Suite struct RawIntegrationTests {
    // MARK: Decode

    @Test(arguments: [RawSamples.sony, RawSamples.iphoneXS, RawSamples.iphone12Pro].compactMap { $0 })
    func decodesWithDefaults(url: URL) throws {
        #expect(ImageSource.isRAW(url: url))
        let develop = try openDevelop(url)
        let image = try #require(develop.apply(.identity, filmApplied: false, draft: false, scale: 1))
        let o = RawSamples.orientation(url)
        let native = develop.nativeSize
        let expected = o.rawValue >= 5 ? CGSize(width: native.height, height: native.width) : native
        #expect(image.extent.size == expected, "extent \(image.extent.size) vs native \(native), orientation \(o.rawValue)")
        #expect(develop.asShot.temperature > 2000 && develop.asShot.temperature < 12000)
        // Without a film nothing reports headroom.
        #expect(image.miraHeadroom == 1)
        print("RAW \(url.lastPathComponent): native \(native), orientation \(o.rawValue), asShot \(develop.asShot)")
    }

    @Test(.enabled(if: RawSamples.sony != nil))
    func draftIsSmallerThanFull() throws {
        let develop = try openDevelop(RawSamples.sony)
        let scale = develop.previewScale()
        let draft = try #require(develop.apply(.identity, filmApplied: false, draft: true, scale: scale))
        let full = try #require(develop.apply(.identity, filmApplied: false, draft: false, scale: 1))
        #expect(scale < 1)
        #expect(max(draft.extent.width, draft.extent.height) <= PreviewSizing.maxSide + 1)
        #expect(draft.extent.width < full.extent.width / 1.5)
        #expect(abs(draft.extent.width / draft.extent.height - full.extent.width / full.extent.height) < 0.01)
        #expect(full.extent.size == develop.nativeSize)
    }

    // MARK: White balance and boost

    @Test(.enabled(if: RawSamples.sony != nil))
    func kelvinWhiteBalanceShiftsColour() throws {
        let develop = try openDevelop(RawSamples.sony)
        let asShot = channelMeans(try linearSmall(develop, .identity, film: false))
        // Treating the scene as lit by 3200 K tungsten (a cooler setting than as shot) must make the
        // picture bluer than as shot... or yellower: decide by direction, then check both ends.
        let cool = channelMeans(try linearSmall(develop, RawSettings(temperature: 3200, tint: 0), film: false))
        let warm = channelMeans(try linearSmall(develop, RawSettings(temperature: 9000, tint: 0), film: false))
        let ratio = { (m: (r: Double, g: Double, b: Double)) in m.b / m.r }
        print("WB b/r: 3200K \(ratio(cool)), as shot (\(develop.asShot.temperature)K) \(ratio(asShot)), 9000K \(ratio(warm))")
        // A lower kelvin setting compensates for warm light: the result is bluer.
        #expect(ratio(cool) > ratio(asShot))
        #expect(ratio(warm) < ratio(asShot))
    }

    @Test(.enabled(if: RawSamples.sony != nil))
    func autoBoostWithFilmIsFlatterThanFullBoost() throws {
        let develop = try openDevelop(RawSamples.sony)
        let auto = try linearSmall(develop, .identity, film: true)
        let explicit0 = try linearSmall(develop, RawSettings(boostAmount: 0), film: true)
        let boost1 = try linearSmall(develop, RawSettings(boostAmount: 1), film: true)
        #expect(auto.rgba == explicit0.rgba, "automatic boost with a film is 0")
        // Midtone flatness: spread (in display encoding) of the pixels whose display value is in the middle.
        func midSpread(_ p: LinearPixels) -> Double {
            let enc = lumas(p).map { RawSamples.srgb(max(0, $0)) }
            let mid = enc.filter { $0 > 0.25 && $0 < 0.75 }
            return stddev(mid)
        }
        let contrast = { (p: LinearPixels) in stddev(lumas(p).map { RawSamples.srgb(max(0, min(1, $0))) }) }
        print("boost 0: mean \(mean(lumas(auto))) contrast \(contrast(auto)); boost 1: mean \(mean(lumas(boost1))) contrast \(contrast(boost1)); mid spread \(midSpread(auto)) / \(midSpread(boost1))")
        // Boost 1 adds the camera's tone curve (brighter midtones, more spread through the middle).
        #expect(mean(lumas(boost1)) > mean(lumas(auto)) * 1.3)
        #expect(midSpread(boost1) > midSpread(auto) || contrast(boost1) > contrast(auto))
    }

    // MARK: Headroom

    @Test(arguments: [RawSamples.sony, RawSamples.iphoneXS, RawSamples.iphone12Pro].compactMap { $0 })
    func extendedRangeReportsHeadroomAndKeepsHighlights(url: URL) throws {
        let develop = try openDevelop(url)
        let source = try #require(develop.develop(.identity, filmApplied: true, draft: true, scale: 0.15))
        let linear = LinearPixels(source.image)
        let peak = Double(stride(from: 0, to: linear.rgba.count, by: 4).map { max(linear.rgba[$0], linear.rgba[$0 + 1], linear.rgba[$0 + 2]) }.max() ?? 0)
        print("HEADROOM \(url.lastPathComponent): reported \(source.headroom), peak at probe scale \(peak)")
        #expect(peak > 1, "film + EDR decodes values above 1.0")
        #expect(source.headroom > 1 && source.headroom <= RawDevelop.maxHeadroom)
        // The measure is a lower bound of the real peak at a reduced decode; same order of magnitude.
        #expect(source.headroom > peak * 0.9 && source.headroom < peak * 1.4 + 0.2)
        // No film: no extended range, no headroom.
        let plain = try #require(develop.develop(.identity, filmApplied: false, draft: true, scale: 0.15))
        #expect(plain.headroom == 1)

        let luma = lumas(linear)
        let threshold = luma.sorted()[Int(Double(luma.count) * 0.95)]
        let top = (0..<luma.count).filter { luma[$0] >= threshold }
        func maxChannel(_ p: LinearPixels, _ i: Int) -> Float { max(p.rgba[i * 4], p.rgba[i * 4 + 1], p.rgba[i * 4 + 2]) }
        let over = top.filter { maxChannel(linear, $0) > 1 }
        let above = over.count
        // Before the film, on the pixels brighter than white: the shoulder keeps their distinct values
        // (16-bit), a clip at white collapses them all.
        let shoulder = LinearPixels(GradeKernels.applyFilmExposure(gain: 1, latitude: 1, headroom: Double(source.headroom), to: source.image))
        func distinct16(_ p: LinearPixels, clip: Bool) -> Int {
            Set(over.map { Int((Double(clip ? min(maxChannel(p, $0), 1) : maxChannel(p, $0)) * 65535).rounded()) }).count
        }
        let a = distinct16(shoulder, clip: false), b = distinct16(linear, clip: true)
        let beyondWhite = (0..<luma.count).filter { maxChannel(shoulder, $0) > 1.0005 }.count
        #expect(Double(beyondWhite) < Double(luma.count) * 0.001, "\(beyondWhite) px above 1 after the shoulder")
        // Through the film: fewer pixels end up at pure white than when the source is clipped.
        let r = Renderer(library: try RawSamples.library())
        let recipe = Recipe(filmID: "neg")
        let withHeadroom = LinearPixels(r.apply(recipe, to: source.image))
        let clipped = LinearPixels(r.apply(recipe, to: source.image, sourceHeadroom: 1))
        func atWhite(_ p: LinearPixels) -> Int { top.filter { p.rgba[$0 * 4 + 1] >= 0.9995 }.count }
        print("HIGHLIGHTS \(url.lastPathComponent): top 5% = \(top.count) px (threshold \(threshold), \(above) above 1.0); distinct 16-bit values among those before the film: \(a) shoulder vs \(b) clipped; \(beyondWhite) px still above 1 after the shoulder; pixels at white after the film: \(atWhite(withHeadroom)) with headroom vs \(atWhite(clipped)) clipped")
        #expect(atWhite(withHeadroom) <= atWhite(clipped))
        if above > 50 {
            #expect(b == 1 && a > 20, "\(a) vs \(b)")
            #expect(atWhite(withHeadroom) < atWhite(clipped))
        }
    }

    // MARK: Export

    @Test(arguments: [RawSamples.sony, RawSamples.iphone12Pro].compactMap { $0 })
    func exportsSixteenBitTiffUpright(url: URL) async throws {
        let r = Renderer(library: try RawSamples.library())
        let recipe = Recipe(filmID: "neg")
        let developed = try #require(ImageSource.developedSourceWithHeadroom(url: url, recipe: recipe, draft: false))
        let space = ImageSource.outputColorSpace(url: url, image: developed.image)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.tiff")
        try r.export(recipe, source: developed.image, metadataFrom: url, outputURL: out, type: .tiff, quality: 1,
                     colorSpace: space)

        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
        let o = RawSamples.orientation(url)
        let native = try openDevelop(url).nativeSize
        let expected = o.rawValue >= 5 ? CGSize(width: native.height, height: native.width) : native
        #expect(CGSize(width: w ?? 0, height: h ?? 0) == expected, "\(w ?? 0)x\(h ?? 0) vs \(expected), source orientation \(o.rawValue)")
        #expect((props[kCGImagePropertyDepth] as? Int) == 16)
        #expect((props[kCGImagePropertyOrientation] as? UInt32 ?? 1) == 1)
        let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(cg.bitsPerComponent == 16)
        #expect(cg.colorSpace?.name as String? == CGColorSpace.displayP3 as String, "colour space \(String(describing: cg.colorSpace?.name))")
        // Without an explicit colour space the export still picks Display P3 for a RAW source.
        let auto = dir.appendingPathComponent("auto.tiff")
        try r.export(recipe, source: developed.image, metadataFrom: url, outputURL: auto, type: .tiff, quality: 1)
        let autoImage = try #require(CGImageSourceCreateWithURL(auto as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(autoImage.colorSpace?.name as String? == CGColorSpace.displayP3 as String, "default space \(String(describing: autoImage.colorSpace?.name))")
        print("EXPORT \(url.lastPathComponent): \(w ?? 0)x\(h ?? 0), depth 16, space \(String(describing: cg.colorSpace?.name)), headroom \(developed.headroom)")
    }

    // MARK: Baseline exposure

    @Test(.enabled(if: RawSamples.iphone12Pro != nil))
    func dngBaselineExposureIsHonoured() throws {
        let url = try #require(RawSamples.iphone12Pro)
        let filter = try #require(CIRAWFilter(imageURL: url))
        print("BASELINE \(url.lastPathComponent): baselineExposure \(filter.baselineExposure)")
        let develop = try openDevelop(url)
        // Default boost, no film: the camera look. Compare with the DNG's embedded preview.
        let mine = try linearSmall(develop, .identity, film: false)
        let myMean = mean(lumas(mine).map { RawSamples.srgb(max(0, min(1, $0))) })
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 400,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        let thumb = try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
        let previewMean = mean(Pixels(CIImage(cgImage: thumb), context: Renderer.sharedContext).luma)
        print("BASELINE mean display luma: Mira \(myMean) vs embedded preview \(previewMean)")
        #expect(abs(myMean - previewMean) < 0.12)
        // And the decoder's own baseline offset is left alone: forcing it to zero changes brightness.
        let flat = try #require(CIRAWFilter(imageURL: url))
        flat.scaleFactor = 0.1
        let before = flat.outputImage.map { mean(lumas(LinearPixels($0))) } ?? 0
        flat.baselineExposure = 0
        let after = flat.outputImage.map { mean(lumas(LinearPixels($0))) } ?? 0
        print("BASELINE linear mean with decoder baseline \(before), forced to 0 \(after)")
        if filter.baselineExposure != 0 { #expect(abs(before - after) > 1e-4) }
    }
}

private extension Double { var clamped01: Double { min(max(self, 0), 1) } }
