import CoreGraphics
import CoreImage
import Foundation

public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public enum CropHit: Equatable, Sendable {
    case handle(CropHandle)
    case move
    case none
}

/// Pure crop maths. Rect functions work in any consistent unit (view points, canvas pixels) with
/// a top-left origin and y pointing down; aspect ratios are width / height.
public enum CropGeometry {
    // MARK: Canvas

    /// Size of the image after `rotate90` (width and height swap for odd quarter turns).
    public static func orientedSize(for crop: CropSettings, size: CGSize) -> CGSize {
        crop.normalizedQuarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// The largest rectangle with the aspect ratio of `size`, centred, that fits inside `size`
    /// rotated by `angle` degrees. Coordinates are in `size` space.
    public static func straightenedBounds(size: CGSize, angle: Double) -> CGRect {
        let a = fitFraction(size: size, angle: angle)
        let w = size.width * a, h = size.height * a
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Side of the inscribed rect relative to the full size (1 at 0 degrees).
    public static func fitFraction(size: CGSize, angle: Double) -> CGFloat {
        let t = abs(angle) * .pi / 180
        let c = CGFloat(cos(t)), s = CGFloat(sin(t))
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return 1 }
        let denomW = w * c + h * s
        let denomH = w * s + h * c
        guard denomW > 0, denomH > 0 else { return 1 }
        return min(1, min(w / denomW, h / denomH))
    }

    // MARK: Transforms (Core Image space: origin bottom-left, y up)

    /// Source -> crop canvas (rotate, flips, straighten with auto-fit), canvas origin at (0, 0).
    public static func canvasTransform(for crop: CropSettings, imageExtent: CGRect) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: -imageExtent.minX, y: -imageExtent.minY)
        var w = imageExtent.width, h = imageExtent.height
        for _ in 0..<crop.normalizedQuarterTurns {
            // Clockwise quarter turn in a y-up space: (x, y) -> (y, w - x).
            t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
            swap(&w, &h)
        }
        if crop.flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        if crop.flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) }
        if abs(crop.straighten) > 1e-9 {
            let fit = fitFraction(size: CGSize(width: w, height: h), angle: crop.straighten)
            let angle = -crop.straighten * .pi / 180 // positive = clockwise on screen
            t = t.concatenating(CGAffineTransform(translationX: -w / 2, y: -h / 2))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
                .concatenating(CGAffineTransform(scaleX: 1 / fit, y: 1 / fit))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
        }
        return t
    }

    /// The crop rect in canvas pixels, y up, rounded to whole pixels and clamped to the canvas.
    public static func cropPixelRect(for crop: CropSettings, canvas: CGSize) -> CGRect {
        let r = crop.rect.clamped()
        let x0 = (r.x * canvas.width).rounded()
        let x1 = ((r.x + r.w) * canvas.width).rounded()
        let top0 = (r.y * canvas.height).rounded()
        let top1 = ((r.y + r.h) * canvas.height).rounded()
        let width = min(max(1, x1 - x0), canvas.width)
        let height = min(max(1, top1 - top0), canvas.height)
        let x = min(max(0, x0), canvas.width - width)
        let topY = min(max(0, top0), canvas.height - height)
        return CGRect(x: x, y: canvas.height - topY - height, width: width, height: height)
    }

    /// Source -> output: `canvasTransform` followed by moving the crop rect to the origin.
    public static func transform(for crop: CropSettings, imageExtent: CGRect) -> CGAffineTransform {
        let canvas = orientedSize(for: crop, size: imageExtent.size)
        let r = cropPixelRect(for: crop, canvas: canvas)
        return canvasTransform(for: crop, imageExtent: imageExtent)
            .concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// Extent of the cropped output, origin (0, 0).
    public static func outputExtent(for crop: CropSettings, imageExtent: CGRect) -> CGRect {
        let canvas = orientedSize(for: crop, size: imageExtent.size)
        let r = cropPixelRect(for: crop, canvas: canvas)
        return CGRect(origin: .zero, size: r.size)
    }

    /// Applies the crop. The identity crop returns `image` untouched (origin moved to zero only
    /// when it is not already there).
    public static func apply(_ crop: CropSettings, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return image }
        if crop.isIdentity {
            return extent.origin == .zero
                ? image : image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        let out = outputExtent(for: crop, imageExtent: extent)
        // Replicating the edge keeps the antialiased border of the rotated image opaque.
        let source = abs(crop.straighten) > 1e-9 ? image.clampedToExtent() : image
        return source.transformed(by: transform(for: crop, imageExtent: extent)).cropped(to: out)
    }

    /// The oriented and straightened picture without the crop rect (what the editor shows while cropping).
    public static func applyCanvas(_ crop: CropSettings, to image: CIImage) -> CIImage {
        apply(crop.withFullRect, to: image)
    }

    // MARK: Rect editing

    /// `size` fitted inside `container` (centred), as for `.aspectRatio(contentMode: .fit)`.
    public static func aspectFit(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let s = min(container.width / contentSize.width, container.height / contentSize.height)
        let w = contentSize.width * s, h = contentSize.height * s
        return CGRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
    }

    /// Moves `rect` inside `bounds` without resizing (shrinks only if it is larger than `bounds`).
    public static func clamp(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let w = min(rect.width, bounds.width), h = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Reshapes `rect` to `aspect` (width / height), keeping its area and centre, shrunk to fit
    /// `bounds` and shifted inside it. A nil aspect only clamps.
    public static func constrain(rect: CGRect, toAspect aspect: Double?, within bounds: CGRect) -> CGRect {
        guard let aspect, aspect > 0, rect.width > 0, rect.height > 0 else { return clamp(rect, within: bounds) }
        let a = CGFloat(aspect)
        let area = rect.width * rect.height
        var w = (area * a).squareRoot()
        var h = w / a
        let k = min(1, bounds.width / w, bounds.height / h)
        w *= k; h *= k
        let r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        return clamp(r, within: bounds)
    }

    /// Moves `rect` by `delta`, clamped inside `bounds`.
    public static func pan(rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        clamp(rect.offsetBy(dx: delta.width, dy: delta.height), within: bounds)
    }

    /// Drags `handle` by `delta`. With an `aspect` the ratio is kept: corners resize from the
    /// opposite corner, edges resize around the centre of the other axis. `minSize` is the minimum
    /// length of the shorter side.
    public static func resize(
        rect: CGRect, handle: CropHandle, by delta: CGSize, aspect: Double?, within bounds: CGRect,
        minSize: CGFloat
    ) -> CGRect {
        let rect = clamp(rect, within: bounds)
        let movesLeft = ([CropHandle.topLeft, .left, .bottomLeft]).contains(handle)
        let movesRight = ([CropHandle.topRight, .right, .bottomRight]).contains(handle)
        let movesTop = ([CropHandle.topLeft, .top, .topRight]).contains(handle)
        let movesBottom = ([CropHandle.bottomLeft, .bottom, .bottomRight]).contains(handle)

        guard let aspect, aspect > 0 else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if movesLeft { minX = min(max(minX + delta.width, bounds.minX), maxX - minSize) }
            if movesRight { maxX = max(min(maxX + delta.width, bounds.maxX), minX + minSize) }
            if movesTop { minY = min(max(minY + delta.height, bounds.minY), maxY - minSize) }
            if movesBottom { maxY = max(min(maxY + delta.height, bounds.maxY), minY + minSize) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        let a = CGFloat(aspect)
        let minW = max(minSize, minSize * a)
        let horizontal = movesLeft || movesRight
        let vertical = movesTop || movesBottom

        if horizontal && vertical {
            let sx: CGFloat = movesRight ? 1 : -1
            let sy: CGFloat = movesBottom ? 1 : -1
            let anchor = CGPoint(x: sx > 0 ? rect.minX : rect.maxX, y: sy > 0 ? rect.minY : rect.maxY)
            let w = max(rect.width + sx * delta.width, 0)
            let h = max(rect.height + sy * delta.height, 0)
            let availW = sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let availH = sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            let maxW = min(availW, availH * a)
            var nw = min((w + h * a) / 2, maxW)
            nw = max(nw, min(minW, maxW))
            let nh = nw / a
            return CGRect(x: sx > 0 ? anchor.x : anchor.x - nw, y: sy > 0 ? anchor.y : anchor.y - nh,
                          width: nw, height: nh)
        }
        if horizontal {
            let sx: CGFloat = movesRight ? 1 : -1
            let anchorX = sx > 0 ? rect.minX : rect.maxX
            let avail = sx > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX
            let maxW = min(avail, 2 * min(rect.midY - bounds.minY, bounds.maxY - rect.midY) * a)
            let nw = min(max(rect.width + sx * delta.width, min(minW, maxW)), maxW)
            let nh = nw / a
            return CGRect(x: sx > 0 ? anchorX : anchorX - nw, y: rect.midY - nh / 2, width: nw, height: nh)
        }
        let sy: CGFloat = movesBottom ? 1 : -1
        let anchorY = sy > 0 ? rect.minY : rect.maxY
        let avail = sy > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY
        let minH = minW / a
        let maxH = min(avail, 2 * min(rect.midX - bounds.minX, bounds.maxX - rect.midX) / a)
        let nh = min(max(rect.height + sy * delta.height, min(minH, maxH)), maxH)
        let nw = nh * a
        return CGRect(x: rect.midX - nw / 2, y: sy > 0 ? anchorY : anchorY - nh, width: nw, height: nh)
    }

    /// Which part of `rect` a pointer at `point` grabs. Corners and edges win within `tolerance`.
    public static func hitTest(point: CGPoint, rect: CGRect, tolerance: CGFloat) -> CropHit {
        let tol = min(tolerance, min(rect.width, rect.height) / 3)
        let nearL = abs(point.x - rect.minX) <= tol
        let nearR = abs(point.x - rect.maxX) <= tol
        let nearT = abs(point.y - rect.minY) <= tol
        let nearB = abs(point.y - rect.maxY) <= tol
        let inX = point.x >= rect.minX - tol && point.x <= rect.maxX + tol
        let inY = point.y >= rect.minY - tol && point.y <= rect.maxY + tol
        guard inX, inY else { return .none }
        if nearT && nearL { return .handle(.topLeft) }
        if nearT && nearR { return .handle(.topRight) }
        if nearB && nearL { return .handle(.bottomLeft) }
        if nearB && nearR { return .handle(.bottomRight) }
        if nearT { return .handle(.top) }
        if nearB { return .handle(.bottom) }
        if nearL { return .handle(.left) }
        if nearR { return .handle(.right) }
        return rect.contains(point) ? .move : .none
    }

    // MARK: Editing the settings

    /// Rotates the crop settings a quarter turn clockwise, turning the rect and the preset with it.
    public static func rotatedClockwise(_ crop: CropSettings) -> CropSettings {
        var c = crop
        let r = crop.rect
        c.rect = CropRect(x: 1 - r.y - r.h, y: r.x, w: r.h, h: r.w)
        c.rotate90 = (crop.normalizedQuarterTurns + 1) % 4
        c.aspect = CropAspect.swapped(crop.aspect)
        // Flips are applied after the rotation, so a horizontal mirror of the old frame is a vertical one of the new.
        c.flipH = crop.flipV
        c.flipV = crop.flipH
        return c
    }

    public static func flippedHorizontally(_ crop: CropSettings) -> CropSettings {
        var c = crop
        c.flipH.toggle()
        c.straighten = -crop.straighten
        c.rect.x = 1 - crop.rect.x - crop.rect.w
        return c
    }

    public static func flippedVertically(_ crop: CropSettings) -> CropSettings {
        var c = crop
        c.flipV.toggle()
        c.straighten = -crop.straighten
        c.rect.y = 1 - crop.rect.y - crop.rect.h
        return c
    }
}
