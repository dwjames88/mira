import CoreGraphics
import Testing
@testable import MiraCameraKit

/// The facts a real phone depends on: a landscape 4032x3024 sensor buffer shown on a portrait phone.
@Suite struct RotationGeometryTests {
    let sensor = CGSize(width: 4032, height: 3024)

    @Test func portraitAngleGivesPortraitAspect() {
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 90) - 3.0 / 4) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 270) - 3.0 / 4) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 0) - 4.0 / 3) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 180) - 4.0 / 3) < 1e-9)
    }

    @Test func portraitPictureFillsTheWidthOfAPortraitFinder() {
        let fit = FinderGeometry.fitRect(aspect: 3.0 / 4, in: CGSize(width: 402, height: 600))
        #expect(abs(fit.width - 402) < 1e-9)
        #expect(abs(fit.height - 536) < 1e-9)
        #expect(abs(fit.minX) < 1e-9)
        #expect(abs(fit.minY - 32) < 1e-9)   // centred: (600 - 536) / 2
    }

    @Test func angle90MapsUprightCornersToDeviceSpace() {
        let size = CGSize(width: 300, height: 400)
        func map(_ x: Double, _ y: Double) -> CGPoint {
            FinderGeometry.devicePoint(viewPoint: CGPoint(x: x, y: y), viewSize: size, uprightAspect: 0.75, rotationAngle: 90)
        }
        let topLeft = map(0, 0)
        #expect(abs(topLeft.x) < 1e-9 && abs(topLeft.y - 1) < 1e-9)
        let topRight = map(300, 0)
        #expect(abs(topRight.x) < 1e-9 && abs(topRight.y) < 1e-9)
    }
}
