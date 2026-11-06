import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

// Load-path orientation regression tests. Every consumer of a photo file (iOS editor, Mac app, Photos
// extension) goes through `ImageSource`, so these prove that EXIF orientation is applied exactly once,
// for the file's own tag (override nil) and for Photos' `fullSizeImageOrientation` override alike.

/// A sensor-orientation test picture with a distinct colour block in each stored corner, written to
/// disk with a chosen EXIF orientation.
enum OrientationFixture {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    enum Mark: String, CaseIterable {
        case red, green, blue, white, grey

        var rgb: (Int, Int, Int) {
            switch self {
            case .red: (255, 0, 0)
            case .green: (0, 255, 0)
            case .blue: (0, 0, 255)
            case .white: (255, 255, 255)
            case .grey: (128, 128, 128)
            }
        }

        /// The nearest palette entry to an 8-bit sample (lossy codecs shift values a little).
        static func nearest(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Mark {
            allCases.min { a, c in distance(a, r, g, b) < distance(c, r, g, b) }!
        }

        private static func distance(_ m: Mark, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
            let (mr, mg, mb) = m.rgb
            return (mr - Int(r)) * (mr - Int(r)) + (mg - Int(g)) * (mg - Int(g)) + (mb - Int(b)) * (mb - Int(b))
        }
    }

    /// The mark painted at each corner of the STORED (sensor-orientation) picture.
    static func mark(at corner: Corner) -> Mark {
        switch corner {
        case .topLeft: .red
        case .topRight: .green
        case .bottomLeft: .blue
        case .bottomRight: .white
        }
    }

    /// Centre of the corner block as fractions of the stored picture (origin top-left, y down).
    static func storedCentre(_ corner: Corner) -> (u: Double, v: Double) {
        switch corner {
        case .topLeft: (0.125, 0.125)
        case .topRight: (0.875, 0.125)
        case .bottomLeft: (0.125, 0.875)
        case .bottomRight: (0.875, 0.875)
        }
    }

    /// Where a point of the stored picture lands once the EXIF orientation is applied (both in
    /// fractions, origin top-left). Written out per tag from the EXIF definition.
    static func displayed(_ p: (u: Double, v: Double), _ o: Int) -> (x: Double, y: Double) {
        switch o {
        case 1: (p.u, p.v)               // as stored
        case 2: (1 - p.u, p.v)           // mirrored horizontally
        case 3: (1 - p.u, 1 - p.v)       // rotated 180
        case 4: (p.u, 1 - p.v)           // mirrored vertically
        case 5: (p.v, p.u)               // transposed
        case 6: (1 - p.v, p.u)           // rotate 90 CW to display
        case 7: (1 - p.v, 1 - p.u)       // transverse
        case 8: (p.v, 1 - p.u)           // rotate 90 CCW to display
        default: fatalError("bad orientation \(o)")
        }
    }

    static func displayedSize(stored: CGSize, _ o: Int) -> CGSize {
        o >= 5 ? CGSize(width: stored.height, height: stored.width) : stored
    }

    static let scratch: URL = {
        let dir = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-designbyjdw-Developer/9314ad8a-9550-4b27-95dd-92363573da5e/scratchpad/orient", isDirectory: true)
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("mira-orient", isDirectory: true)
        for d in [dir, fallback] {
            if (try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)) != nil { return d }
        }
        return fallback
    }()

    static func picture(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ m: Mark, _ rect: CGRect) {
            let (r, g, b) = m.rgb
            ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!)
            ctx.fill(rect)
        }
        let w = CGFloat(width), h = CGFloat(height)
        fill(.grey, CGRect(x: 0, y: 0, width: w, height: h))
        let bw = w / 4, bh = h / 4
        // CGContext origin is bottom-left: the stored TOP row is y = h - bh.
        fill(mark(at: .topLeft), CGRect(x: 0, y: h - bh, width: bw, height: bh))
        fill(mark(at: .topRight), CGRect(x: w - bw, y: h - bh, width: bw, height: bh))
        fill(mark(at: .bottomLeft), CGRect(x: 0, y: 0, width: bw, height: bh))
        fill(mark(at: .bottomRight), CGRect(x: w - bw, y: 0, width: bw, height: bh))
        return ctx.makeImage()!
    }

    static var heicAvailable: Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(UTType.heic.identifier)
    }

    /// Writes the picture with `kCGImagePropertyOrientation = tag` (also the TIFF one, like cameras).
    static func write(type: UTType, tag: Int, width: Int = 64, height: Int = 48, name: String? = nil) throws -> URL {
        let ext = type == .heic ? "heic" : "jpg"
        let url = scratch.appendingPathComponent("\(name ?? "pic")-\(width)x\(height)-o\(tag).\(ext)")
        try? FileManager.default.removeItem(at: url)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil),
                                "no \(type.identifier) encoder")
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: tag,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: tag],
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(dest, picture(width: width, height: height), props as CFDictionary)
        try #require(CGImageDestinationFinalize(dest), "could not encode \(url.lastPathComponent)")
        return url
    }

    /// RGBA8 sRGB bitmap of the image; row 0 is the TOP (Core Image's extent is bottom-left origin,
    /// but `render(toBitmap:)` writes the top row first).
    static func bitmap(_ image: CIImage) -> (width: Int, height: Int, rgba: [UInt8]) {
        let r = image.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Renderer.sharedContext.render(image, toBitmap: &buf, rowBytes: w * 4, bounds: r, format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (w, h, buf)
    }

    /// The palette mark at fractional position (x, y), origin top-left.
    static func markAt(_ bm: (width: Int, height: Int, rgba: [UInt8]), x: Double, y: Double) -> Mark {
        let px = min(max(Int(x * Double(bm.width)), 0), bm.width - 1)
        let py = min(max(Int(y * Double(bm.height)), 0), bm.height - 1)
        let i = (py * bm.width + px) * 4
        return Mark.nearest(bm.rgba[i], bm.rgba[i + 1], bm.rgba[i + 2])
    }

    /// Records an issue per stored corner whose mark is not where the EXIF transform `tag` puts it.
    /// Returns true when everything matched.
    @discardableResult
    static func expectCorners(_ image: CIImage, tag: Int, label: String, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let bm = bitmap(image)
        var ok = true
        for corner in Corner.allCases {
            let at = displayed(storedCentre(corner), tag)
            let found = markAt(bm, x: at.x, y: at.y)
            if found != mark(at: corner) {
                ok = false
                Issue.record("\(label): stored \(corner) (\(mark(at: corner))) should land at displayed (\(at.x), \(at.y)) for tag \(tag), found \(found)",
                             sourceLocation: sourceLocation)
            }
        }
        return ok
    }

    static let tags = [1, 2, 3, 4, 5, 6, 7, 8]
}

private typealias Fx = OrientationFixture

/// One way of loading a file; `nil` result means failure.
private struct Loader: Sendable {
    let name: String
    /// True when the loader returns a reduced-size picture (only the aspect can be checked).
    var reduced = false
    let run: @Sendable (URL, CGImagePropertyOrientation?) -> CIImage?
}

private let loaders: [Loader] = [
    Loader(name: "load") { ImageSource.load(url: $0, orientation: $1) },
    Loader(name: "loadDecoded") { ImageSource.loadDecoded(url: $0, orientation: $1) },
    Loader(name: "loadThumbnail(48)", reduced: true) { ImageSource.loadThumbnail(url: $0, orientation: $1, maxPixelSize: 48) },
    Loader(name: "loadThumbnail(1000)", reduced: true) { ImageSource.loadThumbnail(url: $0, orientation: $1, maxPixelSize: 1000) },
    Loader(name: "loadWithColorSpace") { ImageSource.loadWithColorSpace(url: $0, orientation: $1)?.image },
    Loader(name: "developedSource") { ImageSource.developedSource(url: $0, orientation: $1, recipe: .neutral, draft: false) },
    Loader(name: "developedSource(draft)") { ImageSource.developedSource(url: $0, orientation: $1, recipe: .neutral, draft: true) },
]

@Suite("Load-path orientation") struct ImageSourceOrientationTests {
    private func check(type: UTType) throws {
        for tag in Fx.tags {
            let url = try Fx.write(type: type, tag: tag)
            let stored = CGSize(width: 64, height: 48)
            let expected = Fx.displayedSize(stored: stored, tag)
            let override = try #require(CGImagePropertyOrientation(rawValue: UInt32(tag)))

            // Header-only size.
            #expect(ImageSource.orientedPixelSize(url: url) == expected, "\(type.preferredFilenameExtension ?? "") tag \(tag) orientedPixelSize(nil)")
            #expect(ImageSource.orientedPixelSize(url: url, orientation: override) == expected, "tag \(tag) orientedPixelSize(override)")

            for loader in loaders {
                for (mode, o) in [("nil", CGImagePropertyOrientation?.none), ("override", override)] {
                    let label = "\(type.preferredFilenameExtension ?? "") tag \(tag) \(loader.name) orientation=\(mode)"
                    guard let image = loader.run(url, o) else {
                        Issue.record("\(label): returned nil")
                        continue
                    }
                    let e = image.extent
                    if loader.reduced {
                        #expect((e.width > e.height) == (expected.width > expected.height), "\(label): aspect \(e.size)")
                    } else {
                        #expect(e.size == expected, "\(label): extent \(e.size), expected \(expected)")
                    }
                    Fx.expectCorners(image, tag: tag, label: label)
                }
            }
        }
    }

    @Test func jpegOrientationIsAppliedOnceByEveryLoader() throws {
        try check(type: .jpeg)
    }

    @Test(.enabled(if: Fx.heicAvailable, "HEIC encoder unavailable on this machine"))
    func heicOrientationIsAppliedOnceByEveryLoader() throws {
        try check(type: .heic)
    }

    /// The reported bug class: orientation applied twice (once by the decoder, once by Mira) turns a
    /// portrait shot upside down. Override == the file's own tag must be identical to nil.
    @Test(arguments: [UTType.jpeg, UTType.heic])
    func overrideEqualToFileTagMatchesNil(type: UTType) throws {
        try #require(type != .heic || Fx.heicAvailable, "HEIC encoder unavailable")
        let url = try Fx.write(type: type, tag: 6, width: 64, height: 48)
        let six = CGImagePropertyOrientation.right
        for loader in loaders where !loader.reduced {
            let a = try #require(loader.run(url, nil))
            let b = try #require(loader.run(url, six))
            #expect(a.extent == b.extent, "\(loader.name) extent")
            let pa = Fx.bitmap(a), pb = Fx.bitmap(b)
            let worst = zip(pa.rgba, pb.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 1, "\(loader.name): override 6 differs from nil by \(worst)/255")
            // Never the 180-degree result. Tag 6 (rotate 90 CW): stored TL red -> top-right, TR green ->
            // bottom-right, BL blue -> top-left, BR white -> bottom-left.
            #expect(Fx.markAt(pb, x: 0.875, y: 0.125) == .red, "\(loader.name): red not top-right")
            #expect(Fx.markAt(pb, x: 0.875, y: 0.875) == .green, "\(loader.name): green not bottom-right")
            #expect(Fx.markAt(pb, x: 0.125, y: 0.125) == .blue, "\(loader.name): blue not top-left")
            #expect(Fx.markAt(pb, x: 0.125, y: 0.875) == .white, "\(loader.name): white not bottom-left")
        }
    }

    /// Camera-sized geometry: a 4032x3024 sensor-orientation file tagged 6 opens as 3024x4032.
    @Test func cameraSizedHEICTag6IsPortrait() throws {
        try #require(Fx.heicAvailable, "HEIC encoder unavailable")
        let url = try Fx.write(type: .heic, tag: 6, width: 4032, height: 3024, name: "camera")
        #expect(ImageSource.orientedPixelSize(url: url) == CGSize(width: 3024, height: 4032))
        let image = try #require(ImageSource.loadDecoded(url: url))
        #expect(image.extent.size == CGSize(width: 3024, height: 4032))
        Fx.expectCorners(image, tag: 6, label: "camera-size loadDecoded")
        let thumb = try #require(ImageSource.loadThumbnail(url: url, maxPixelSize: 1600))
        #expect(thumb.extent.height > thumb.extent.width)
        #expect(max(thumb.extent.width, thumb.extent.height) <= 1600)
        Fx.expectCorners(thumb, tag: 6, label: "camera-size loadThumbnail")
    }

    // MARK: Export

    @Test func exportWritesUprightPixelsWithOrientationOne() throws {
        let renderer = Renderer(library: try emptyLibrary())
        let url = try Fx.write(type: .jpeg, tag: 6)
        let loaded = try #require(ImageSource.loadWithColorSpace(url: url))
        #expect(loaded.image.extent.size == CGSize(width: 48, height: 64))

        let viaSource = Fx.scratch.appendingPathComponent("export-source.jpg")
        let viaURL = Fx.scratch.appendingPathComponent("export-url.jpg")
        try? FileManager.default.removeItem(at: viaSource)
        try? FileManager.default.removeItem(at: viaURL)
        try renderer.export(.neutral, source: loaded.image, metadataFrom: url, outputURL: viaSource,
                            type: .jpeg, quality: 1, colorSpace: loaded.colorSpace)
        try renderer.export(.neutral, inputURL: url, outputURL: viaURL, type: .jpeg, quality: 1)

        for out in [viaSource, viaURL] {
            let label = out.lastPathComponent
            let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            #expect(props[kCGImagePropertyOrientation] as? Int == 1, "\(label) orientation \(String(describing: props[kCGImagePropertyOrientation]))")
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let o = tiff[kCGImagePropertyTIFFOrientation] as? Int {
                #expect(o == 1, "\(label) TIFF orientation")
            }
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 48, "\(label) width")
            #expect(props[kCGImagePropertyPixelHeight] as? Int == 64, "\(label) height")
            // ImageIO's raw decode ignores orientation, so these are the pixels as written.
            let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect(cg.width == 48 && cg.height == 64)
            Fx.expectCorners(CIImage(cgImage: cg), tag: 6, label: "\(label) written pixels")
            // And a consumer that does honour orientation sees the same picture, not a second rotation.
            let reread = try #require(ImageSource.load(url: out))
            #expect(reread.extent.size == CGSize(width: 48, height: 64))
            Fx.expectCorners(reread, tag: 6, label: "\(label) re-read")
        }
    }

    // MARK: DNG

    /// ImageIO's own embedded-preview thumbnail with the EXIF transform applied is the reference for
    /// "upright"; the RAW paths must agree with it, not with a flipped or rotated copy.
    @Test(arguments: [RawSamples.iphoneXS, RawSamples.iphone12Pro].compactMap { $0 })
    func dngLoadsUprightLikeImageIOPreview(url: URL) throws {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        let refCG = try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary))
        let ref = CIImage(cgImage: refCG)
        let portrait = ref.extent.height > ref.extent.width
        let tag = RawSamples.orientation(url).rawValue
        print("DNG \(url.lastPathComponent): file orientation \(tag), reference thumbnail \(ref.extent.size)")

        let develop = try #require(RawDevelop(url: url))
        let candidates: [(String, CIImage)] = [
            ("ImageSource.load", try #require(ImageSource.load(url: url))),
            ("RawDevelop(url:)", try #require(develop.apply(.identity, filmApplied: false, draft: true, scale: 0.25))),
        ]
        let grid = portrait ? (w: 24, h: 32) : (w: 32, h: 24)
        let refLuma = Self.lumaGrid(ref, grid: grid)
        for (name, image) in candidates {
            #expect((image.extent.height > image.extent.width) == portrait, "\(url.lastPathComponent) \(name): extent \(image.extent.size) vs reference \(ref.extent.size)")
            let luma = Self.lumaGrid(image, grid: grid)
            let upright = Self.correlation(luma, refLuma)
            let vflip = Self.correlation(Self.flippedVertically(luma, grid: grid), refLuma)
            let rot180 = Self.correlation(luma.reversed(), refLuma)
            print("DNG \(url.lastPathComponent) \(name): upright \(upright), vflip \(vflip), rot180 \(rot180)")
            #expect(upright > vflip, "\(url.lastPathComponent) \(name): upright \(upright) <= vflip \(vflip)")
            #expect(upright > rot180, "\(url.lastPathComponent) \(name): upright \(upright) <= rot180 \(rot180)")
            #expect(upright > 0.5, "\(url.lastPathComponent) \(name): weak correlation \(upright)")
        }
    }

    /// Luma of the image scaled to a grid, top row first.
    private static func lumaGrid(_ image: CIImage, grid: (w: Int, h: Int)) -> [Double] {
        let e = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(grid.w) / e.width, y: CGFloat(grid.h) / e.height))
            .cropped(to: CGRect(x: 0, y: 0, width: grid.w, height: grid.h))
        let bm = Fx.bitmap(scaled)
        return (0..<(bm.width * bm.height)).map {
            0.2126 * Double(bm.rgba[$0 * 4]) + 0.7152 * Double(bm.rgba[$0 * 4 + 1]) + 0.0722 * Double(bm.rgba[$0 * 4 + 2])
        }
    }

    private static func flippedVertically(_ v: [Double], grid: (w: Int, h: Int)) -> [Double] {
        (0..<grid.h).reversed().flatMap { row in Array(v[(row * grid.w)..<((row + 1) * grid.w)]) }
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }
}
