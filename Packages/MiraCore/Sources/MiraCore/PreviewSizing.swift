import CoreGraphics
import Foundation

/// Pure sizing rules for interactive previews.
public enum PreviewSizing {
    /// How many pixels to render per canvas pixel. 1 renders exactly what the canvas can show
    /// (on a Retina display that is twice the canvas in points).
    public static let oversample: CGFloat = 1
    /// Long side used until the view reports its size (and in headless hosts).
    public static let fallbackLongSide: CGFloat = 1600
    /// Never render a preview larger than this on either side.
    public static let maxSide: CGFloat = 3072
    /// Canvas sizes are rounded up to this many pixels so a window resize does not rebuild the
    /// preview source for every pixel of movement.
    public static let quantum: CGFloat = 64

    public static func quantised(canvas: CGSize) -> CGSize {
        func up(_ v: CGFloat) -> CGFloat { max(quantum, (v / quantum).rounded(.up) * quantum) }
        return CGSize(width: up(canvas.width), height: up(canvas.height))
    }

    /// Pixel size to render `content` (the cropped output, in source pixels) for `canvas` (pixels).
    /// The picture is fitted inside `oversample x canvas`, capped at `maxSide`, and never upscaled.
    /// A nil canvas uses `fallbackLongSide`.
    public static func renderSize(content: CGSize, canvas: CGSize?) -> CGSize {
        guard content.width > 0, content.height > 0 else { return CGSize(width: 1, height: 1) }
        var box = canvas.map { CGSize(width: $0.width * oversample, height: $0.height * oversample) }
            ?? CGSize(width: fallbackLongSide, height: fallbackLongSide)
        box.width = min(max(box.width, 1), maxSide)
        box.height = min(max(box.height, 1), maxSide)
        let k = min(1, box.width / content.width, box.height / content.height)
        if k >= 1 { return CGSize(width: content.width.rounded(), height: content.height.rounded()) }
        return CGSize(width: max(1, (content.width * k).rounded()), height: max(1, (content.height * k).rounded()))
    }
}

/// Coalesces bursts of render requests: at most one in flight, the latest request waits and
/// replaces any older waiting one, so stale frames are never rendered.
public struct RenderGate<Request: Sendable>: Sendable {
    public private(set) var isBusy = false
    public private(set) var pending: Request?
    /// Requests discarded before they ran.
    public private(set) var dropped = 0

    public init() {}

    /// Returns `request` when it should start now, nil when it was queued behind the running one.
    public mutating func submit(_ request: Request) -> Request? {
        guard isBusy else {
            isBusy = true
            return request
        }
        if pending != nil { dropped += 1 }
        pending = request
        return nil
    }

    /// Call when the running request ends. Returns the request to start next, if any.
    public mutating func finish() -> Request? {
        if let next = pending {
            pending = nil
            return next
        }
        isBusy = false
        return nil
    }

    /// Forgets the waiting request (the running one still finishes).
    public mutating func cancelPending() {
        if pending != nil { dropped += 1 }
        pending = nil
    }
}
