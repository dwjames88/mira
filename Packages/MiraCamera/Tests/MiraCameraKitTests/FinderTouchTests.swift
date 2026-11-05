import CoreGraphics
import Testing
@testable import MiraCameraKit

@Suite struct FinderGeometryTests {
    @Test func fitRectLetterboxesAndPillarboxes() {
        let wide = FinderGeometry.fitRect(aspect: 4.0 / 3, in: CGSize(width: 400, height: 600))
        #expect(wide == CGRect(x: 0, y: 150, width: 400, height: 300))
        let tall = FinderGeometry.fitRect(aspect: 3.0 / 4, in: CGSize(width: 400, height: 400))
        #expect(tall == CGRect(x: 50, y: 0, width: 300, height: 400))
    }

    @Test func uprightAspectSwapsForQuarterTurns() {
        let sensor = CGSize(width: 4032, height: 3024)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 90) - 0.75) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 270) - 0.75) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: 0) - 4.0 / 3) < 1e-9)
        #expect(abs(FinderGeometry.uprightAspect(sensorSize: sensor, rotationAngle: -90) - 0.75) < 1e-9)
    }

    @Test func portraitTapMapsToDevicePoint() {
        // A 3:4 picture exactly filling a 300x400 view, portrait (90 degrees).
        let size = CGSize(width: 300, height: 400)
        func map(_ x: Double, _ y: Double, _ angle: Double = 90) -> CGPoint {
            FinderGeometry.devicePoint(viewPoint: CGPoint(x: x, y: y), viewSize: size, uprightAspect: 0.75, rotationAngle: angle)
        }
        let topLeft = map(0, 0)
        #expect(abs(topLeft.x - 0) < 1e-9 && abs(topLeft.y - 1) < 1e-9)
        let topRight = map(300, 0)
        #expect(abs(topRight.x - 0) < 1e-9 && abs(topRight.y - 0) < 1e-9)
        let bottomLeft = map(0, 400)
        #expect(abs(bottomLeft.x - 1) < 1e-9 && abs(bottomLeft.y - 1) < 1e-9)
        let centre = map(150, 200)
        #expect(abs(centre.x - 0.5) < 1e-9 && abs(centre.y - 0.5) < 1e-9)
    }

    @Test func tapsInLetterboxBarsClampToTheEdgeOfThePicture() {
        // A 4:3 landscape picture (angle 0) in a tall 400x600 view: bars above and below.
        let p = FinderGeometry.devicePoint(viewPoint: CGPoint(x: 200, y: 10), viewSize: CGSize(width: 400, height: 600),
                                           uprightAspect: 4.0 / 3, rotationAngle: 0)
        #expect(p == CGPoint(x: 0.5, y: 0))
    }

    @Test func halfTurnsInvert() {
        let size = CGSize(width: 400, height: 300)
        let p = FinderGeometry.devicePoint(viewPoint: CGPoint(x: 100, y: 75), viewSize: size, uprightAspect: 4.0 / 3, rotationAngle: 180)
        #expect(abs(p.x - 0.75) < 1e-9 && abs(p.y - 0.75) < 1e-9)
        let q = FinderGeometry.devicePoint(viewPoint: CGPoint(x: 0, y: 0), viewSize: CGSize(width: 300, height: 400), uprightAspect: 0.75, rotationAngle: 270)
        #expect(abs(q.x - 1) < 1e-9 && abs(q.y - 0) < 1e-9)
    }
}

@Suite struct FinderTouchTrackerTests {
    @Test func quickReleaseIsATap() {
        var t = FinderTouchTracker()
        t.begin(at: CGPoint(x: 10, y: 20))
        #expect(t.end(after: 0.1) == .tapFocus(CGPoint(x: 10, y: 20)))
    }

    @Test func holdShowsOriginalThenReleaseHidesIt() {
        var t = FinderTouchTracker()
        t.begin(at: .zero)
        #expect(t.held(for: 0.25) == .showOriginal(true))
        #expect(t.end(after: 0.4) == .showOriginal(false))
    }

    @Test func heldPastHalfSecondLocksAndHidesTheOriginal() {
        var t = FinderTouchTracker()
        t.begin(at: CGPoint(x: 5, y: 5))
        #expect(t.held(for: 0.25) == .showOriginal(true))
        #expect(t.held(for: 0.5) == .lock(CGPoint(x: 5, y: 5)))
        #expect(t.phase == .locked)
        #expect(t.end(after: 0.8) == .none)
    }

    @Test func movementCancelsAndHidesTheOriginal() {
        var t = FinderTouchTracker()
        t.begin(at: .zero)
        #expect(t.move(to: CGPoint(x: 6, y: 6)) == .none)   // 8.5 pt: still a touch
        #expect(t.held(for: 0.25) == .showOriginal(true))
        #expect(t.move(to: CGPoint(x: 12, y: 0)) == .showOriginal(false))
        #expect(t.held(for: 0.5) == .none)
        #expect(t.end(after: 0.6) == .none)
    }

    @Test func slowReleaseBeforeLockDoesNotFocus() {
        var t = FinderTouchTracker()
        t.begin(at: .zero)
        #expect(t.end(after: 0.3) == .none)
    }
}
