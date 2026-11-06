import CoreImage
import Metal
import MiraCore
import QuartzCore
import XCTest
@testable import Mira

/// A real `CAMetalLayer` drawable, as `MTKView` hands to `MetalPreviewView.draw`. Core Image writes a drawable
/// texture top-row-first (it recognises drawables) but a plain Metal texture bottom-row-first, so a test that
/// wants to see what the screen sees must render into a drawable, not into an offscreen texture.
@MainActor
enum DrawableCanvas {
    /// RGBA8, top row first, exactly what ended up on the drawable.
    struct Frame {
        var w: Int
        var h: Int
        var px: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
    }

    /// `LivePreview.render` into a fresh drawable of `size` pixels (one call, like `MetalPreviewView.draw`), read back by a blit.
    static func render(_ live: LivePreview, size: CGSize, recipe: Recipe, cropping: Bool = false,
                       showingOriginal: Bool = false, zoom: CGFloat = 1, offset: CGSize = .zero, contentScale: CGFloat = 3,
                       ink: CIColor) -> Frame? {
        guard let device = live.device, let queue = live.commandQueue else { return nil }
        let w = Int(size.width), h = Int(size.height)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: w, height: h)
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return nil }
        live.render(into: drawable.texture, commandBuffer: cb, recipe: recipe, cropping: cropping,
                    showingOriginal: showingOriginal, zoom: zoom, offset: offset, contentScale: contentScale, ink: ink)
        cb.commit()
        cb.waitUntilCompleted()
        guard let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let readback = queue.makeCommandBuffer(), let blit = readback.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        readback.commit()
        readback.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: buffer.contents(), count: w * h * 4)) }
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }   // BGRA -> RGBA
        return Frame(w: w, h: h, px: px)
    }

    /// The centroid (pixels, top-left origin) of the pixels where `weight` is positive, weighted by it; nil if none.
    static func centroid(of frame: Frame, weight: (Int, Int, Int) -> Double) -> CGPoint? {
        var sx = 0.0, sy = 0.0, total = 0.0
        for y in 0..<frame.h {
            for x in 0..<frame.w {
                let c = frame.rgb(x, y)
                let v = weight(c.r, c.g, c.b)
                if v > 0 { sx += v * Double(x); sy += v * Double(y); total += v }
            }
        }
        return total > 0 ? CGPoint(x: sx / total, y: sy / total) : nil
    }

    static func red(_ r: Int, _ g: Int, _ b: Int) -> Double { Double(max(0, r - max(g, b) - 60)) }
    static func green(_ r: Int, _ g: Int, _ b: Int) -> Double { Double(max(0, g - max(r, b) - 40)) }

    /// RGBA8 pixels of a CGImage, top row first.
    static func frame(of image: CGImage) -> Frame {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Frame(w: w, h: h, px: px)
    }

    /// A synthetic asymmetric picture, upright: dark grey with a saturated red block in the visual top-left and a
    /// green block in the top-right, both above the middle and inside the middle half of the picture's height, so
    /// they survive every aspect crop and a 2x zoom. Rows are written top first, which is how `CIImage(bitmapData:)`
    /// and `CGImage` read them.
    static func markedPicture(width w: Int, height h: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = 64; px[i + 1] = 64; px[i + 2] = 64; px[i + 3] = 255 }
        func block(x0: Double, x1: Double, rgb: (UInt8, UInt8, UInt8)) {
            for y in Int(0.30 * Double(h))..<Int(0.42 * Double(h)) {
                for x in Int(x0 * Double(w))..<Int(x1 * Double(w)) {
                    let i = (y * w + x) * 4
                    px[i] = rgb.0; px[i + 1] = rgb.1; px[i + 2] = rgb.2
                }
            }
        }
        block(x0: 0.28, x1: 0.42, rgb: (255, 0, 0))
        block(x0: 0.58, x1: 0.72, rgb: (0, 230, 20))
        let data = CFDataCreate(nil, px, px.count)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// XCTest asserts: red in the top-left, green in the top-right of `frame`, around `centre` (default: the frame's own).
    static func assertMarksUpright(_ frame: Frame, _ label: String, centre: CGPoint? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let c = centre ?? CGPoint(x: Double(frame.w) / 2, y: Double(frame.h) / 2)
        guard let r = centroid(of: frame, weight: red), let g = centroid(of: frame, weight: green) else {
            XCTFail("\(label): marks not found", file: file, line: line); return
        }
        XCTAssertLessThan(r.x, c.x, "\(label): red must be left (red \(r), green \(g))", file: file, line: line)
        XCTAssertGreaterThan(g.x, c.x, "\(label): green must be right (red \(r), green \(g))", file: file, line: line)
        XCTAssertLessThan(r.y, c.y, "\(label): red must be above the middle (red \(r), green \(g))", file: file, line: line)
        XCTAssertLessThan(g.y, c.y, "\(label): green must be above the middle (red \(r), green \(g))", file: file, line: line)
    }
}
