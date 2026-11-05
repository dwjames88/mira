import CoreImage
import MiraCamera
import XCTest

/// `FinderRenderer.upright` turns the camera's landscape buffer upright. CIImage is y-up, so the buffer's visual
/// top-left is CI (small x, large y). A back camera on a portrait phone reports 90: the buffer turns 90 degrees
/// CLOCKWISE, so the buffer's visual top-left lands at the upright top-RIGHT and its bottom-left at the upright top-LEFT.
final class FinderUprightTests: XCTestCase {
    // Distinct marks, 40x40 in each corner of a 400x300 landscape buffer (visual positions).
    private enum Mark {
        static let topLeft = CIColor(red: 1, green: 0, blue: 0)
        static let topRight = CIColor(red: 0, green: 1, blue: 0)
        static let bottomLeft = CIColor(red: 0, green: 0, blue: 1)
        static let bottomRight = CIColor(red: 1, green: 1, blue: 0)
    }

    private func buffer() -> CIImage {
        let w: CGFloat = 400, h: CGFloat = 300, m: CGFloat = 40
        var image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        func mark(_ color: CIColor, _ rect: CGRect) {
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        mark(Mark.topLeft, CGRect(x: 0, y: h - m, width: m, height: m))
        mark(Mark.topRight, CGRect(x: w - m, y: h - m, width: m, height: m))
        mark(Mark.bottomLeft, CGRect(x: 0, y: 0, width: m, height: m))
        mark(Mark.bottomRight, CGRect(x: w - m, y: 0, width: m, height: m))
        return image
    }

    private func upright(_ angle: Double) -> CIImage {
        FinderRenderer.upright(FinderFrame(image: buffer(), rotationAngle: angle, exposureTime: nil, timestamp: 0, index: 0), crop: nil)
    }

    /// RGB bytes at the visual (top-left origin) pixel of the image's centre of the corner square.
    private func corners(_ image: CIImage) -> (tl: [UInt8], tr: [UInt8], bl: [UInt8], br: [UInt8]) {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
        // Bitmap rows run top to bottom.
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * w + x) * 4 ..< (y * w + x) * 4 + 3]) }
        return (px(20, 20), px(w - 21, 20), px(20, h - 21), px(w - 21, h - 21))
    }

    private let red: [UInt8] = [255, 0, 0], green: [UInt8] = [0, 255, 0], blue: [UInt8] = [0, 0, 255], yellow: [UInt8] = [255, 255, 0]

    func testAngle0IsUnchanged() {
        let image = upright(0)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 400, height: 300))
        let c = corners(image)
        XCTAssertEqual(c.tl, red); XCTAssertEqual(c.tr, green); XCTAssertEqual(c.bl, blue); XCTAssertEqual(c.br, yellow)
    }

    func testAngle90TurnsTheBufferClockwise() {
        let image = upright(90)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 300, height: 400))
        let c = corners(image)
        XCTAssertEqual(c.tr, red, "buffer top-left -> upright top-right")
        XCTAssertEqual(c.br, green, "buffer top-right -> upright bottom-right")
        XCTAssertEqual(c.tl, blue, "buffer bottom-left -> upright top-left (the scene's top-left held upright)")
        XCTAssertEqual(c.bl, yellow, "buffer bottom-right -> upright bottom-left")
    }

    func testAngle180() {
        let image = upright(180)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 400, height: 300))
        let c = corners(image)
        XCTAssertEqual(c.br, red); XCTAssertEqual(c.bl, green); XCTAssertEqual(c.tr, blue); XCTAssertEqual(c.tl, yellow)
    }

    func testAngle270TurnsTheBufferCounterClockwise() {
        let image = upright(270)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 300, height: 400))
        let c = corners(image)
        XCTAssertEqual(c.bl, red, "buffer top-left -> upright bottom-left")
        XCTAssertEqual(c.tl, green, "buffer top-right -> upright top-left")
        XCTAssertEqual(c.br, blue, "buffer bottom-left -> upright bottom-right")
        XCTAssertEqual(c.tr, yellow, "buffer bottom-right -> upright top-right")
    }

    func testAspectCropIsCentredOnTheUprightFrame() {
        // 400x300 buffer at 90 degrees is 300x400 upright; 3:2 keeps the full height and 266.67 of the width.
        let frame = FinderFrame(image: buffer(), rotationAngle: 90, exposureTime: nil, timestamp: 0, index: 0)
        let cropped = FinderRenderer.upright(frame, crop: nil, aspect: .threeTwo)
        XCTAssertEqual(cropped.extent.minX, 0); XCTAssertEqual(cropped.extent.minY, 0)
        XCTAssertEqual(cropped.extent.width, 400 / 1.5, accuracy: 1)
        XCTAssertEqual(cropped.extent.height, 400, accuracy: 1)
        XCTAssertEqual(cropped.extent.height / cropped.extent.width, 1.5, accuracy: 0.01)
        let none = FinderRenderer.upright(frame, crop: nil, aspect: .fourThree)
        XCTAssertEqual(none.extent, CGRect(x: 0, y: 0, width: 300, height: 400))
    }
}
