import CoreImage
import MiraCamera
import MiraCameraKit
import Synchronization
import XCTest

/// The fake camera behaves like a back camera: for angle `a` it emits a sensor-orientation buffer (landscape for
/// 90/270) stamped `a`, which `FinderRenderer.upright` turns into the same upright picture.
final class FakeFrameSourceRotationTests: XCTestCase {
    private func frame(angle: Double) -> FinderFrame? {
        let source = FakeFrameSource(fixtureURL: CameraFixtures.sampleURL)
        let box = Mutex<FinderFrame?>(nil)
        let got = expectation(description: "frame \(angle)")
        got.assertForOverFulfill = false
        source.setHandler { f in box.withLock { $0 = f }; got.fulfill() }
        source.setRotationAngle(angle)
        source.start()
        wait(for: [got], timeout: 5)
        source.stop()
        return box.withLock { $0 }
    }

    /// Visual RGB bytes (top-left origin) at 48 px wide.
    private func pixels(_ image: CIImage) -> (w: Int, h: Int, bytes: [UInt8]) {
        let scale = 48 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width.rounded()), h = Int(small.extent.height.rounded())
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(small, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (w, h, bytes)
    }

    private func meanAbsDiff(_ a: CIImage, _ b: CIImage) -> Double {
        let p = pixels(a), q = pixels(b)
        guard p.w == q.w, abs(p.h - q.h) <= 1 else { return 255 }
        let h = min(p.h, q.h)
        var total = 0, n = 0
        for y in 0..<h { for x in 0..<(p.w * 4) where x % 4 != 3 {
            total += abs(Int(p.bytes[y * p.w * 4 + x]) - Int(q.bytes[y * q.w * 4 + x])); n += 1
        } }
        return Double(total) / Double(n)
    }

    func testEveryAngleIsStampedAndShapedLikeASensorBuffer() throws {
        for angle in [0.0, 90, 180, 270] {
            let f = try XCTUnwrap(frame(angle: angle))
            XCTAssertEqual(f.rotationAngle, angle)
            let e = f.image.extent
            XCTAssertEqual(e.minX, 0); XCTAssertEqual(e.minY, 0)
            XCTAssertEqual(e.width / e.height, 4.0 / 3, accuracy: 0.01, "buffer is landscape 4:3 at \(angle)")
            let up = FinderRenderer.upright(f, crop: nil).extent
            let portrait = angle == 90 || angle == 270
            XCTAssertEqual(up.width / up.height, portrait ? 3.0 / 4 : 4.0 / 3, accuracy: 0.01, "upright shape at \(angle)")
        }
    }

    func testDefaultIsPortrait() throws {
        let source = FakeFrameSource(fixtureURL: CameraFixtures.sampleURL)
        let box = Mutex<FinderFrame?>(nil)
        let got = expectation(description: "frame")
        got.assertForOverFulfill = false
        source.setHandler { f in box.withLock { $0 = f }; got.fulfill() }
        source.start()
        wait(for: [got], timeout: 5)
        source.stop()
        XCTAssertEqual(box.withLock { $0 }?.rotationAngle, 90)
    }

    func testOppositeAnglesGiveTheSameUprightPicture() throws {
        let up = { (a: Double) in FinderRenderer.upright(try XCTUnwrap(self.frame(angle: a)), crop: nil) }
        XCTAssertLessThan(meanAbsDiff(try up(90), try up(270)), 3, "90 and 270 are the same upright portrait")
        XCTAssertLessThan(meanAbsDiff(try up(0), try up(180)), 3, "0 and 180 are the same upright landscape")
    }
}
