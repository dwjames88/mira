import CoreGraphics
import CoreImage
import Foundation
@testable import EmulsionCore

enum Fixture {
    /// Horizontal gradient on top, colour patches below, as an sRGB CIImage.
    static func gradientAndPatches(size: Int) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size)
        for x in 0..<size {
            let v = CGFloat(x) / CGFloat(size - 1)
            ctx.setFillColor(CGColor(colorSpace: space, components: [v, v, v, 1])!)
            ctx.fill(CGRect(x: CGFloat(x), y: s * 0.5, width: 1, height: s * 0.5))
        }
        let patches: [[CGFloat]] = [
            [0.8, 0.2, 0.2], [0.2, 0.7, 0.3], [0.2, 0.3, 0.85], [0.9, 0.8, 0.2],
            [0.85, 0.6, 0.5], [0.5, 0.5, 0.5], [0.3, 0.2, 0.15], [0.9, 0.9, 0.9],
        ]
        let w = s / CGFloat(patches.count)
        for (i, p) in patches.enumerated() {
            ctx.setFillColor(CGColor(colorSpace: space, components: p + [1])!)
            ctx.fill(CGRect(x: CGFloat(i) * w, y: 0, width: w, height: s * 0.5))
        }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    static func solid(gray: CGFloat, size: Int) -> CIImage {
        let c = CIColor(red: gray, green: gray, blue: gray, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }
}

struct Pixels {
    let width: Int, height: Int
    let rgba: [UInt8]

    init(_ image: CIImage, context: CIContext) {
        let r = image.extent
        width = Int(r.width); height = Int(r.height)
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &buf, rowBytes: width * 4, bounds: r, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        rgba = buf
    }

    var count: Int { width * height }

    func channel(_ c: Int) -> [Double] { (0..<count).map { Double(rgba[$0 * 4 + c]) / 255 } }
    var luma: [Double] {
        let r = channel(0), g = channel(1), b = channel(2)
        return (0..<count).map { 0.2126 * r[$0] + 0.7152 * g[$0] + 0.0722 * b[$0] }
    }
}

func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
func stddev(_ v: [Double]) -> Double {
    let m = mean(v)
    return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(v.count, 1))).squareRoot()
}

/// Empty library for tests that don't need films.
func emptyLibrary() throws -> FilmLibrary {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emulsion-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: dir.appendingPathComponent("films.json"))
    return try FilmLibrary(directory: dir)
}
