import CoreGraphics
import Foundation

/// Where a touch on the finder lands on the sensor, accounting for the aspect-fit rect and the frame's rotation.
public enum FinderGeometry {
    /// The rect an image of `aspect` (width / height) occupies when aspect-fit and centered in `size`.
    public static func fitRect(aspect: Double, in size: CGSize) -> CGRect {
        guard aspect > 0, aspect.isFinite, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            let h = size.width / aspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        }
        let w = size.height * aspect
        return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
    }

    /// Width / height of the frame as displayed (upright): the sensor image rotated by `rotationAngle`.
    public static func uprightAspect(sensorSize: CGSize, rotationAngle: Double) -> Double {
        guard sensorSize.width > 0, sensorSize.height > 0 else { return 3.0 / 4.0 }
        let quarter = Int((normalized(rotationAngle) / 90).rounded()) % 4
        return quarter % 2 == 1 ? sensorSize.height / sensorSize.width : sensorSize.width / sensorSize.height
    }

    /// Size of the sensor image once turned upright by `rotationAngle`.
    public static func uprightSize(sensorSize: CGSize, rotationAngle: Double) -> CGSize {
        let quarter = Int((normalized(rotationAngle) / 90).rounded()) % 4
        return quarter % 2 == 1 ? CGSize(width: sensorSize.height, height: sensorSize.width) : sensorSize
    }

    /// The aspect crop (`CaptureCrop.cropRect`) of the upright frame, normalized, top-left origin; the whole frame
    /// for `.fourThree` (the sensor's own shape is "no crop").
    public static func cropRect(sensorSize: CGSize, rotationAngle: Double, aspect: CaptureAspect) -> CGRect {
        guard aspect != .fourThree else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CaptureCrop.cropRect(frameSize: uprightSize(sensorSize: sensorSize, rotationAngle: rotationAngle), aspect: aspect)
    }

    /// Width / height of what the finder shows: the upright frame after the aspect crop.
    public static func croppedAspect(sensorSize: CGSize, rotationAngle: Double, aspect: CaptureAspect) -> Double {
        let size = uprightSize(sensorSize: sensorSize, rotationAngle: rotationAngle)
        let crop = cropRect(sensorSize: sensorSize, rotationAngle: rotationAngle, aspect: aspect)
        guard size.width > 0, size.height > 0, crop.height > 0 else { return 3.0 / 4.0 }
        return (size.width * crop.width) / (size.height * crop.height)
    }

    /// A point on the finder view -> the point in AVFoundation's device space (0...1, origin top left of the
    /// landscape sensor image). `rotationAngle` is the angle the sensor image is rotated clockwise to appear upright
    /// (90 for a portrait phone). Points outside the picture are clamped to its edge.
    /// `uprightAspect` is the aspect of what is drawn (after `crop`); `crop` is the part of the upright frame that is
    /// drawn (normalized, top-left origin), so the view point maps into the cropped frame, then into the whole upright
    /// frame, then to the sensor.
    public static func devicePoint(
        viewPoint: CGPoint, viewSize: CGSize, uprightAspect: Double, rotationAngle: Double,
        crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> CGPoint {
        let fit = fitRect(aspect: uprightAspect, in: viewSize)
        let cu = min(max((viewPoint.x - fit.minX) / max(fit.width, 1), 0), 1)
        let cv = min(max((viewPoint.y - fit.minY) / max(fit.height, 1), 0), 1)
        let u = crop.minX + cu * crop.width
        let v = crop.minY + cv * crop.height
        switch Int((normalized(rotationAngle) / 90).rounded()) % 4 {
        case 1: return CGPoint(x: v, y: 1 - u)         // portrait
        case 2: return CGPoint(x: 1 - u, y: 1 - v)
        case 3: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    private static func normalized(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }
}

/// One finger on the finder, resolved into a gesture. The three single-finger gestures share a touch, so the
/// time and movement decide:
/// - released within `showOriginalAfter` (0.25 s), moved less than `movementLimit` (12 pt): TAP, focus and meter;
/// - held past 0.25 s without moving: the bare scene shows while held (the editor's hold to compare), and it
///   goes away on release (release before 0.5 s = just a look, no focus change);
/// - held past `lockAfter` (0.5 s): AE/AF LOCK at the point; the bare scene hides again;
/// - moving 12 pt or more at any time cancels all three (a pinch or a drag).
public struct FinderTouchTracker: Sendable, Equatable {
    public static let showOriginalAfter = 0.25
    public static let lockAfter = 0.5
    public static let movementLimit = 12.0

    public enum Phase: Sendable, Equatable { case idle, down, showingOriginal, locked, cancelled }

    public enum Action: Sendable, Equatable {
        case none
        case tapFocus(CGPoint)
        case showOriginal(Bool)
        case lock(CGPoint)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var origin: CGPoint = .zero

    public init() {}

    public mutating func begin(at point: CGPoint) {
        phase = .down
        origin = point
    }

    /// Movement past the limit cancels. Returns `.showOriginal(false)` when the bare scene was up.
    public mutating func move(to point: CGPoint) -> Action {
        guard phase == .down || phase == .showingOriginal || phase == .locked else { return .none }
        guard hypot(point.x - origin.x, point.y - origin.y) >= Self.movementLimit else { return .none }
        return cancel()
    }

    /// The touch has been down for `elapsed` seconds. Call at 0.25 s and 0.5 s (calling later or twice is harmless).
    public mutating func held(for elapsed: Double) -> Action {
        switch phase {
        case .down where elapsed >= Self.lockAfter:
            phase = .locked
            return .lock(origin)
        case .down where elapsed >= Self.showOriginalAfter:
            phase = .showingOriginal
            return .showOriginal(true)
        case .showingOriginal where elapsed >= Self.lockAfter:
            phase = .locked
            return .lock(origin)
        default:
            return .none
        }
    }

    /// The finger lifted after `elapsed` seconds.
    public mutating func end(after elapsed: Double) -> Action {
        defer { phase = .idle }
        switch phase {
        case .down: return elapsed < Self.showOriginalAfter ? .tapFocus(origin) : .none
        case .showingOriginal: return .showOriginal(false)
        default: return .none
        }
    }

    /// A second finger arrived (pinch) or the touch moved too far.
    @discardableResult
    public mutating func cancel() -> Action {
        let wasShowing = phase == .showingOriginal
        phase = .cancelled
        return wasShowing ? .showOriginal(false) : .none
    }

    public mutating func reset() { phase = .idle }
}
