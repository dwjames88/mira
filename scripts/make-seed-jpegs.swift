// Generates N small varied JPEGs (gradients + shapes, distinct per index) for the library perf sim.
// usage: swiftc -O tools/make-seed-jpegs.swift -o build/seed/gen && build/seed/gen <outdir> <count>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let n = Int(CommandLine.arguments[2])!
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var rng = SystemRandomNumberGenerator()
let space = CGColorSpaceCreateDeviceRGB()
for i in 0..<n {
    let w = 320, h = i % 3 == 0 ? 240 : 320
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func c(_ s: Int) -> CGFloat { CGFloat((i &* 2654435761 &+ s &* 40503) % 256) / 255 }
    let g = CGGradient(colorsSpace: space, colors: [CGColor(red: c(1), green: c(2), blue: c(3), alpha: 1),
                                                    CGColor(red: c(4), green: c(5), blue: c(6), alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    for k in 0..<4 {
        ctx.setFillColor(CGColor(red: c(7 + k), green: c(11 + k), blue: c(13 + k), alpha: 0.8))
        let r = CGRect(x: CGFloat((i * 37 + k * 71) % w) - 40, y: CGFloat((i * 53 + k * 29) % h) - 40, width: 40 + CGFloat((i + k * 13) % 90), height: 40 + CGFloat((i * 3 + k * 7) % 90))
        k % 2 == 0 ? ctx.fillEllipse(in: r) : ctx.fill(r)
    }
    let img = ctx.makeImage()!
    let url = out.appendingPathComponent(String(format: "seed-%05d.jpg", i))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    // EXIF date spread over ~6 years so creation dates differ (newest first sort is meaningful).
    let date = Date(timeIntervalSince1970: 1_450_000_000 + Double(i) * 41_000)
    let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: f.string(from: date)],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: f.string(from: date)]]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("wrote \(n)")
