import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MiraCore
import Testing
import UniformTypeIdentifiers
@testable import MiraUI

/// `EditorModel.loadSource(url:orientation:)` is what the Photos extension (with Photos'
/// `fullSizeImageOrientation`) and the Mac app call. A sensor-orientation file tagged 6 must open as a
/// portrait picture with the stored top-left block at the displayed top-right, once, for nil and for
/// an explicit override equal to the tag, including the reduced stand-in shown for large files.
@MainActor
@Suite("Editor load orientation", .serialized)
struct EditorLoadOrientationTests {
    private enum Mark: CaseIterable { case red, green, blue, white, grey
        var rgb: (Int, Int, Int) {
            switch self {
            case .red: (255, 0, 0)
            case .green: (0, 255, 0)
            case .blue: (0, 0, 255)
            case .white: (255, 255, 255)
            case .grey: (128, 128, 128)
            }
        }
    }

    private static let scratch: URL = {
        let dir = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-designbyjdw-Developer/9314ad8a-9550-4b27-95dd-92363573da5e/scratchpad/orient", isDirectory: true)
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("mira-orient-ui", isDirectory: true)
        for d in [dir, fallback] where (try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)) != nil { return d }
        return fallback
    }()

    /// Stored picture: red top-left, green top-right, blue bottom-left, white bottom-right, grey between.
    private static func writeJPEG(width: Int, height: Int, tag: Int) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ m: Mark, _ r: CGRect) {
            ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(m.rgb.0) / 255, CGFloat(m.rgb.1) / 255, CGFloat(m.rgb.2) / 255, 1])!)
            ctx.fill(r)
        }
        let w = CGFloat(width), h = CGFloat(height), bw = w / 4, bh = h / 4
        fill(.grey, CGRect(x: 0, y: 0, width: w, height: h))
        fill(.red, CGRect(x: 0, y: h - bh, width: bw, height: bh))
        fill(.green, CGRect(x: w - bw, y: h - bh, width: bw, height: bh))
        fill(.blue, CGRect(x: 0, y: 0, width: bw, height: bh))
        fill(.white, CGRect(x: w - bw, y: 0, width: bw, height: bh))
        let url = scratch.appendingPathComponent("editor-\(width)x\(height)-o\(tag).jpg")
        try? FileManager.default.removeItem(at: url)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyOrientation: tag,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: tag],
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return url
    }

    private static func mark(_ image: CIImage, x: Double, y: Double) -> Mark {
        let r = image.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        Renderer.sharedContext.render(image, toBitmap: &buf, rowBytes: w * 4, bounds: r, format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)   // row 0 is the top
        let px = min(max(Int(x * Double(w)), 0), w - 1), py = min(max(Int(y * Double(h)), 0), h - 1)
        let i = (py * w + px) * 4
        func d(_ m: Mark) -> Int {
            let dr = m.rgb.0 - Int(buf[i]), dg = m.rgb.1 - Int(buf[i + 1]), db = m.rgb.2 - Int(buf[i + 2])
            return dr * dr + dg * dg + db * db
        }
        return Mark.allCases.min { d($0) < d($1) }!
    }

    /// Tag 6 (rotate 90 CW to display): TL red -> top-right, TR green -> bottom-right,
    /// BL blue -> top-left, BR white -> bottom-left.
    private static func expectTag6(_ image: CIImage?, _ label: String) {
        guard let image else { Issue.record("\(label): no source"); return }
        #expect(image.extent.height > image.extent.width, "\(label): not portrait, \(image.extent.size)")
        #expect(mark(image, x: 0.875, y: 0.125) == .red, "\(label): red not top-right")
        #expect(mark(image, x: 0.875, y: 0.875) == .green, "\(label): green not bottom-right")
        #expect(mark(image, x: 0.125, y: 0.125) == .blue, "\(label): blue not top-left")
        #expect(mark(image, x: 0.125, y: 0.875) == .white, "\(label): white not bottom-left")
    }

    private static func makeModel() throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        model.setCanvas(pixels: CGSize(width: 1200, height: 800))
        return model
    }

    @Test(arguments: [nil, CGImagePropertyOrientation.right])
    func smallTag6FileOpensPortraitAndUpright(override: CGImagePropertyOrientation?) async throws {
        let url = try Self.writeJPEG(width: 64, height: 48, tag: 6)
        let model = try Self.makeModel()
        #expect(model.loadSource(url: url, orientation: override))
        #expect(model.isSourceFull)
        #expect(model.source?.extent.size == CGSize(width: 48, height: 64))
        Self.expectTag6(model.source, "small override=\(String(describing: override))")
        Self.expectTag6(await model.fullSource(), "small fullSource override=\(String(describing: override))")
    }

    /// Longer than the stand-in threshold: the first frame is the reduced thumbnail, then the full decode
    /// replaces it. Both must be upright.
    @Test(arguments: [nil, CGImagePropertyOrientation.right])
    func largeTag6FileStandInAndFullDecodeAreUpright(override: CGImagePropertyOrientation?) async throws {
        let long = Int(EditorModel.standInThreshold) + 200   // 2800 x 2100 stored
        let url = try Self.writeJPEG(width: long, height: long * 3 / 4, tag: 6)
        let model = try Self.makeModel()
        #expect(model.loadSource(url: url, orientation: override))
        #expect(!model.isSourceFull, "expected a reduced stand-in first")
        Self.expectTag6(model.source, "stand-in override=\(String(describing: override))")
        let full = await model.fullSource()
        #expect(full?.extent.size == CGSize(width: long * 3 / 4, height: long))
        Self.expectTag6(full, "full override=\(String(describing: override))")
        Self.expectTag6(model.source, "source after full decode override=\(String(describing: override))")
    }
}
