import CoreGraphics
import MiraCore

/// The rules for editing a curve's control points, kept apart from the view so they can be tested.
/// A curve always keeps its two endpoints (x = 0 and x = 1), which only move vertically; interior
/// points stay strictly between their neighbours.
enum CurveEditing {
    /// Smallest horizontal gap between neighbouring points.
    static let minGap = 0.004

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Adds a point at `x` on the curve itself and returns its index (an existing point is reused
    /// when `x` is within `minGap` of it).
    @discardableResult
    static func addPoint(_ points: inout [CurvePoint], atX x: Double) -> Int {
        let curve = MonotoneCurve(points)
        let x = clamp01(x)
        if let i = points.firstIndex(where: { abs($0.x - x) < minGap }) { return i }
        let p = CurvePoint(x: x, y: curve.value(at: x))
        let index = points.firstIndex { $0.x > x } ?? points.count
        points.insert(p, at: index)
        return index
    }

    /// Moves point `index` to `target`, keeping the order. Endpoints keep their x.
    static func move(_ points: inout [CurvePoint], index: Int, to target: CGPoint) {
        guard points.indices.contains(index) else { return }
        let isFirst = index == 0, isLast = index == points.count - 1
        var x = points[index].x
        if !isFirst && !isLast {
            let lo = points[index - 1].x + minGap, hi = points[index + 1].x - minGap
            x = min(max(Double(target.x), lo), max(lo, hi))
        }
        points[index] = CurvePoint(x: clamp01(x), y: clamp01(Double(target.y)))
    }

    /// Removes an interior point; endpoints cannot be deleted. Returns whether anything changed.
    @discardableResult
    static func delete(_ points: inout [CurvePoint], index: Int) -> Bool {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return false }
        points.remove(at: index)
        return true
    }

    /// Nudges a point by `dx`, `dy` (fractions of the square).
    static func nudge(_ points: inout [CurvePoint], index: Int, dx: Double, dy: Double) {
        guard points.indices.contains(index) else { return }
        move(&points, index: index, to: CGPoint(x: points[index].x + dx, y: points[index].y + dy))
    }

    /// The point within `radius` (in the same units as the square's points) of `location`.
    static func hit(_ points: [CurvePoint], at location: CGPoint, size: CGSize, radius: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in points.enumerated() {
            let d = hypot(CGFloat(p.x) * size.width - location.x, (1 - CGFloat(p.y)) * size.height - location.y)
            if d <= radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// Where `location` (view points, origin top left) lies in curve space, unclamped.
    static func curvePoint(for location: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: location.x / max(size.width, 1), y: 1 - location.y / max(size.height, 1))
    }

    /// True when a drag has left the square far enough to delete the point.
    static func isOutside(_ location: CGPoint, size: CGSize, margin: CGFloat = 14) -> Bool {
        location.x < -margin || location.y < -margin || location.x > size.width + margin || location.y > size.height + margin
    }

    /// `IN 128 · OUT 141` on the 0...255 scale.
    static func readout(_ p: CurvePoint) -> String {
        "IN \(Int((p.x * 255).rounded())) \u{00B7} OUT \(Int((p.y * 255).rounded()))"
    }
}

/// Maps a click in the preview pane to a point on the displayed picture.
enum PreviewHitMapping {
    /// Fractions (0...1, origin top left) of the picture shown aspect-fit inside `pane` with
    /// `inset` on every side; nil when the click is outside the picture.
    static func normalizedPoint(_ location: CGPoint, pane: CGSize, inset: CGFloat, image: CGSize) -> CGPoint? {
        let avail = CGSize(width: pane.width - 2 * inset, height: pane.height - 2 * inset)
        guard avail.width > 0, avail.height > 0, image.width > 0, image.height > 0 else { return nil }
        let scale = min(avail.width / image.width, avail.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (pane.width - shown.width) / 2, y: (pane.height - shown.height) / 2)
        let p = CGPoint(x: (location.x - origin.x) / shown.width, y: (location.y - origin.y) / shown.height)
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return nil }
        return p
    }
}
