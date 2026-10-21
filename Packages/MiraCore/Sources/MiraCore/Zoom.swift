import CoreGraphics
import Foundation

/// How the editor shows the picture: fitted in the pane, or zoomed to `scale` around `center`.
///
/// Units: `scale` is device pixels per picture pixel, so 1 is "100%" (one picture pixel on one
/// screen pixel). `center` is the point of the picture at the middle of the pane, in picture
/// pixels (the cropped output, border included), origin top left, y down.
public struct ZoomState: Equatable, Sendable {
    /// nil while fitted.
    public var scale: Double?
    public var center: CGPoint

    public static let fit = ZoomState(scale: nil, center: .zero)

    public init(scale: Double?, center: CGPoint) {
        self.scale = scale
        self.center = center
    }

    public var isFit: Bool { scale == nil }
}

/// The geometry the zoom maths works in, all sizes in device pixels except `content`.
public struct ZoomViewport: Equatable, Sendable {
    /// The whole picture as shown (cropped, with its border), in picture pixels.
    public var content: CGSize
    /// The pane the picture is shown in.
    public var pane: CGSize
    /// The area fit mode letterboxes the picture into (the pane minus its padding).
    public var fitArea: CGSize

    public init(content: CGSize, pane: CGSize, fitArea: CGSize? = nil) {
        self.content = content
        self.pane = pane
        self.fitArea = fitArea ?? pane
    }

    public var isValid: Bool {
        content.width >= 1 && content.height >= 1 && pane.width >= 1 && pane.height >= 1
            && fitArea.width >= 1 && fitArea.height >= 1
    }
}

/// A region of the picture at `scale`, in scaled picture pixels (picture pixels x scale), origin top
/// left: what a zoomed render produces.
public struct ZoomRegion: Equatable, Hashable, Sendable {
    public var scale: Double
    public var rect: CGRect

    public init(scale: Double, rect: CGRect) {
        self.scale = scale
        self.rect = rect
    }
}

/// Pure zoom and pan rules. No UI, no rendering.
public enum ZoomGeometry {
    /// The zoom steps between fit and 400%, in order. Steps at or below the fit scale are skipped.
    public static let levels: [Double] = [0.5, 1, 2, 4]

    // MARK: Scale and centre

    /// Picture pixels to device pixels when fitted.
    public static func fitScale(_ vp: ZoomViewport) -> Double {
        guard vp.isValid else { return 1 }
        return Double(min(vp.fitArea.width / vp.content.width, vp.fitArea.height / vp.content.height))
    }

    public static func scale(of state: ZoomState, in vp: ZoomViewport) -> Double {
        state.scale ?? fitScale(vp)
    }

    /// Keeps the view on the picture: an axis the picture fills may not scroll past the edges, an
    /// axis it does not fill stays centred.
    public static func clampCenter(_ c: CGPoint, scale: Double, in vp: ZoomViewport) -> CGPoint {
        func axis(_ v: CGFloat, content: CGFloat, pane: CGFloat) -> CGFloat {
            let s = CGFloat(scale)
            guard content * s > pane else { return content / 2 }
            let half = pane / (2 * s)
            return min(max(v, half), content - half)
        }
        return CGPoint(x: axis(c.x, content: vp.content.width, pane: vp.pane.width),
                       y: axis(c.y, content: vp.content.height, pane: vp.pane.height))
    }

    /// The centre actually shown: the picture's middle while fitted, else the clamped `center`.
    public static func center(of state: ZoomState, in vp: ZoomViewport) -> CGPoint {
        guard let scale = state.scale else { return CGPoint(x: vp.content.width / 2, y: vp.content.height / 2) }
        return clampCenter(state.center, scale: scale, in: vp)
    }

    // MARK: Mapping

    /// The picture point under `pane` (device pixels in the pane), not clamped to the picture.
    public static func contentPoint(atPane p: CGPoint, state: ZoomState, in vp: ZoomViewport) -> CGPoint {
        let c = center(of: state, in: vp)
        let s = CGFloat(scale(of: state, in: vp))
        return CGPoint(x: c.x + (p.x - vp.pane.width / 2) / s, y: c.y + (p.y - vp.pane.height / 2) / s)
    }

    /// Where a rectangle of the picture lands in the pane.
    public static func paneRect(ofContentRect r: CGRect, state: ZoomState, in vp: ZoomViewport) -> CGRect {
        let c = center(of: state, in: vp)
        let s = CGFloat(scale(of: state, in: vp))
        return CGRect(x: vp.pane.width / 2 + (r.minX - c.x) * s, y: vp.pane.height / 2 + (r.minY - c.y) * s,
                      width: r.width * s, height: r.height * s)
    }

    /// The part of the picture on screen, in picture pixels, clipped to the picture.
    public static func visibleContentRect(state: ZoomState, in vp: ZoomViewport) -> CGRect {
        let whole = CGRect(origin: .zero, size: vp.content)
        guard !state.isFit else { return whole }
        let c = center(of: state, in: vp)
        let s = CGFloat(scale(of: state, in: vp))
        let w = vp.pane.width / s, h = vp.pane.height / s
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h).intersection(whole)
    }

    /// The pixels to render for a zoomed state: the on-screen part at the zoom scale, snapped out to
    /// whole pixels. nil while fitted.
    public static func renderRegion(state: ZoomState, in vp: ZoomViewport) -> ZoomRegion? {
        guard let s = state.scale, vp.isValid else { return nil }
        let c = center(of: state, in: vp)
        let origin = CGPoint(x: c.x * CGFloat(s) - vp.pane.width / 2, y: c.y * CGFloat(s) - vp.pane.height / 2)
        let whole = CGRect(x: 0, y: 0, width: vp.content.width * CGFloat(s), height: vp.content.height * CGFloat(s))
        let visible = CGRect(origin: origin, size: vp.pane).intersection(whole)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let x0 = visible.minX.rounded(.down), y0 = visible.minY.rounded(.down)
        let x1 = visible.maxX.rounded(.up), y1 = visible.maxY.rounded(.up)
        return ZoomRegion(scale: s, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    // MARK: Transitions

    /// The scale a click on the fitted picture zooms to.
    public static let clickScale: Double = 2

    /// A click on the picture: fit zooms to 200% centred on the click point, zoomed returns to fit.
    /// A picture that already fills the pane at that scale at fit has nothing to zoom to.
    public static func clicked(_ state: ZoomState, atPane p: CGPoint, in vp: ZoomViewport) -> ZoomState {
        guard vp.isValid else { return state }
        guard state.isFit else { return .fit }
        guard fitScale(vp) < clickScale - 1e-6 else { return state }
        let point = clampToContent(contentPoint(atPane: p, state: state, in: vp), in: vp)
        return ZoomState(scale: clickScale, center: clampCenter(point, scale: clickScale, in: vp))
    }

    /// The scales the keys step through: fit, then each level above the fit scale.
    public static func ladder(in vp: ZoomViewport) -> [Double?] {
        let fit = fitScale(vp)
        return [nil] + levels.filter { $0 > fit * 1.001 }.map { Optional($0) }
    }

    /// One step up (`direction` > 0) or down along `ladder`, clamped at both ends, keeping the
    /// picture point under `anchor` (a pane point; the pane centre when nil) where it is.
    public static func stepped(_ state: ZoomState, by direction: Int, anchor: CGPoint?, in vp: ZoomViewport) -> ZoomState {
        guard vp.isValid, direction != 0 else { return state }
        let steps = ladder(in: vp)
        let current = currentIndex(of: state, in: steps)
        let next = min(max(current + (direction > 0 ? 1 : -1), 0), steps.count - 1)
        guard next != current else { return state }
        guard let newScale = steps[next] else { return .fit }
        let a = anchor ?? CGPoint(x: vp.pane.width / 2, y: vp.pane.height / 2)
        let p = clampToContent(contentPoint(atPane: a, state: state, in: vp), in: vp)
        let center = CGPoint(x: p.x - (a.x - vp.pane.width / 2) / CGFloat(newScale),
                             y: p.y - (a.y - vp.pane.height / 2) / CGFloat(newScale))
        return ZoomState(scale: newScale, center: clampCenter(center, scale: newScale, in: vp))
    }

    /// Drags the picture by `delta` device pixels (positive moves it right/down). Ignored while fitted.
    public static func panned(_ state: ZoomState, byPane delta: CGSize, in vp: ZoomViewport) -> ZoomState {
        guard let s = state.scale, vp.isValid else { return state }
        let c = center(of: state, in: vp)
        let moved = CGPoint(x: c.x - delta.width / CGFloat(s), y: c.y - delta.height / CGFloat(s))
        return ZoomState(scale: s, center: clampCenter(moved, scale: s, in: vp))
    }

    /// Pinch: multiplies the scale by `factor`, between fit and the top level (400%), keeping the
    /// picture point under `anchor` (a pane point) where it is. At or below the fit scale it is fit.
    public static func scaled(_ state: ZoomState, by factor: Double, anchor: CGPoint, in vp: ZoomViewport) -> ZoomState {
        guard vp.isValid, factor > 0, factor.isFinite else { return state }
        let fit = fitScale(vp)
        let top = levels.last ?? 4
        let newScale = min(scale(of: state, in: vp) * factor, max(top, fit))
        if newScale <= fit * 1.001 { return .fit }
        let p = clampToContent(contentPoint(atPane: anchor, state: state, in: vp), in: vp)
        let center = CGPoint(x: p.x - (anchor.x - vp.pane.width / 2) / CGFloat(newScale),
                             y: p.y - (anchor.y - vp.pane.height / 2) / CGFloat(newScale))
        return ZoomState(scale: newScale, center: clampCenter(center, scale: newScale, in: vp))
    }

    /// The same state re-expressed for a changed viewport (window resize): fit stays fit; a zoomed
    /// state keeps its scale and has its centre re-clamped.
    public static func revalidated(_ state: ZoomState, in vp: ZoomViewport) -> ZoomState {
        guard let s = state.scale, vp.isValid else { return state }
        // Zoom below the new fit scale makes no sense: go back to fit.
        if s <= fitScale(vp) * 1.001 { return .fit }
        return ZoomState(scale: s, center: clampCenter(state.center, scale: s, in: vp))
    }

    // MARK: Readout

    /// "100%", "50%", or "FIT".
    public static func readout(for state: ZoomState) -> String {
        guard let s = state.scale else { return "Fit" }
        return "\(Int((s * 100).rounded()))%"
    }

    // MARK: Helpers

    private static func clampToContent(_ p: CGPoint, in vp: ZoomViewport) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), vp.content.width), y: min(max(p.y, 0), vp.content.height))
    }

    private static func currentIndex(of state: ZoomState, in steps: [Double?]) -> Int {
        guard let s = state.scale else { return 0 }
        var best = 1, bestDistance = Double.infinity
        for (i, step) in steps.enumerated() {
            guard let step else { continue }
            let d = abs(log(step / s))
            if d < bestDistance { best = i; bestDistance = d }
        }
        return min(best, max(steps.count - 1, 0))
    }
}
