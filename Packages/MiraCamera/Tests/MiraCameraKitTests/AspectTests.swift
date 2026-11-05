import CoreGraphics
import Foundation
import MiraCore
import Testing
@testable import MiraCameraKit

@Suite struct AspectTests {
    func near(_ a: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
        abs(a.minX - x) < 1e-9 && abs(a.minY - y) < 1e-9 && abs(a.width - w) < 1e-9 && abs(a.height - h) < 1e-9
    }

    @Test func oldSettingsDecodeWithFourThree() throws {
        let old = #"{"silentShutter":true,"addLocation":false,"finderQuality":"auto"}"#
        let settings = try JSONDecoder().decode(CameraSettings.self, from: Data(old.utf8))
        #expect(settings.aspect == .fourThree)
        #expect(settings.silentShutter)
        var changed = settings
        changed.aspect = .xpan
        let round = try JSONDecoder().decode(CameraSettings.self, from: JSONEncoder().encode(changed))
        #expect(round.aspect == .xpan)
    }

    @Test func labelsAndRatios() {
        #expect(CaptureAspect.allCases.map(\.rawValue) == ["4:3", "3:2", "1:1", "16:9", "65:24"])
        #expect(CaptureAspect.xpan.label == "XPAN 65:24")
        #expect(abs(CaptureAspect.xpan.longOverShort - 65.0 / 24) < 1e-12)
    }

    @Test func fourThreeOnFourThreeIsWhole() {
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 4032, height: 3024), aspect: .fourThree), 0, 0, 1, 1))
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 3024, height: 4032), aspect: .fourThree), 0, 0, 1, 1))
    }

    @Test func cropFollowsTheFramesLongAxis() {
        let third = 1.0 - (4.0 / 3) / 1.5   // 0.1111: share removed from the short side's... of the long axis
        // 3:2 of a landscape 4:3 frame: full width, shorter height. Of a portrait frame: full height, narrower width.
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 4032, height: 3024), aspect: .threeTwo), 0, third / 2, 1, 1 - third))
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 3024, height: 4032), aspect: .threeTwo), third / 2, 0, 1 - third, 1))
        // Square of a 4:3 frame loses a quarter of the long side.
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 4032, height: 3024), aspect: .square), 0.125, 0, 0.75, 1))
        #expect(near(CaptureCrop.cropRect(frameSize: CGSize(width: 3024, height: 4032), aspect: .square), 0, 0.125, 1, 0.75))
        // The cropped pixels really have the aspect's ratio.
        for aspect in CaptureAspect.allCases {
            let size = CGSize(width: 3024, height: 4032)
            let r = CaptureCrop.cropRect(frameSize: size, aspect: aspect)
            let w = r.width * size.width, h = r.height * size.height
            #expect(abs(max(w, h) / min(w, h) - aspect.longOverShort) < 1e-9, "\(aspect)")
            #expect(h >= w)   // stays portrait
        }
    }

    @Test func recipeCropForAPortraitPhoto() throws {
        let crop = try #require(CaptureCrop.recipeCrop(sensorSize: PixelSize(width: 4032, height: 3024), rotationAngle: 90, aspect: .threeTwo))
        #expect(abs(crop.rect.x - 0.0555555555) < 1e-6)
        #expect(crop.rect.y == 0)
        #expect(abs(crop.rect.w - 0.8888888888) < 1e-6)
        #expect(crop.rect.h == 1)
        #expect(crop.aspectID == "2:3")
    }

    @Test func recipeCropByOrientationAndAspect() throws {
        let sensor = PixelSize(width: 4032, height: 3024)
        #expect(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 90, aspect: .fourThree) == nil)
        #expect(try #require(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 0, aspect: .threeTwo)).aspectID == "3:2")
        #expect(try #require(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 180, aspect: .sixteenNine)).aspectID == "16:9")
        #expect(try #require(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 270, aspect: .sixteenNine)).aspectID == "9:16")
        #expect(try #require(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 90, aspect: .square)).aspectID == "square")
        let xpan = try #require(CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: 90, aspect: .xpan))
        #expect(xpan.aspectID == "24:65")
        #expect(abs(CropAspect.ratio(id: xpan.aspectID, canvas: .zero)! - 24.0 / 65) < 1e-12)
        #expect(abs(CropAspect.ratio(id: "65:24", canvas: .zero)! - 65.0 / 24) < 1e-12)
        // The rect, applied to the upright size, has the aspect's ratio.
        let w = xpan.rect.w * 3024, h = xpan.rect.h * 4032
        #expect(abs(h / w - 65.0 / 24) < 1e-9)
    }

    @Test func croppedAspectAndTouchMapping() {
        // A 4000x3000 sensor turned 90 degrees is 3000x4000 upright; 1:1 keeps the middle three quarters of the height.
        let sensor = CGSize(width: 4000, height: 3000)
        let crop = FinderGeometry.cropRect(sensorSize: sensor, rotationAngle: 90, aspect: .square)
        #expect(near(crop, 0, 0.125, 1, 0.75))
        let aspect = FinderGeometry.croppedAspect(sensorSize: sensor, rotationAngle: 90, aspect: .square)
        #expect(abs(aspect - 1) < 1e-9)
        #expect(abs(FinderGeometry.croppedAspect(sensorSize: sensor, rotationAngle: 90, aspect: .fourThree) - 0.75) < 1e-9)
        let view = CGSize(width: 300, height: 300)
        func map(_ x: Double, _ y: Double) -> CGPoint {
            FinderGeometry.devicePoint(viewPoint: CGPoint(x: x, y: y), viewSize: view, uprightAspect: aspect, rotationAngle: 90, crop: crop)
        }
        // View top-left = upright (0, 0.125) -> device (v, 1 - u) = (0.125, 1).
        let a = map(0, 0)
        #expect(abs(a.x - 0.125) < 1e-9 && abs(a.y - 1) < 1e-9)
        // View bottom-right = upright (1, 0.875) -> device (0.875, 0).
        let b = map(300, 300)
        #expect(abs(b.x - 0.875) < 1e-9 && abs(b.y) < 1e-9)
        let c = map(150, 150)
        #expect(abs(c.x - 0.5) < 1e-9 && abs(c.y - 0.5) < 1e-9)
    }
}
