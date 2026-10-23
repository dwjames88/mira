import CoreGraphics
import CoreImage
import Foundation

extension Renderer {
    /// Masks for pictures with a longer side than this are built at reduced size (or for the visible
    /// region only) and enlarged, so a 24 MP export does not need a 100 MB mask per layer.
    static let maskLongSide: CGFloat = 4096

    /// The mask geometry used to grade an image of `size` (Core Image pixels).
    static func dodgeBurnGeometry(crop: CropSettings, sourceSize: CGSize, size: CGSize, region: CGRect?) -> DodgeBurnGeometry {
        let long = max(size.width, size.height)
        if long <= maskLongSide {
            return DodgeBurnGeometry(crop: crop, sourceSize: sourceSize, gradedSize: size)
        }
        if let region {
            return DodgeBurnGeometry(crop: crop, sourceSize: sourceSize, gradedSize: size, region: region, scale: 1)
        }
        return DodgeBurnGeometry(crop: crop, sourceSize: sourceSize, gradedSize: size, scale: Double(maskLongSide / long))
    }

    /// Lightens and darkens `image` (the cropped picture) under the painted masks.
    func applyDodgeBurn(_ settings: DodgeBurnSettings, to image: CIImage, crop: CropSettings,
                        sourceSize: CGSize, region: CGRect?) -> CIImage {
        let extent = image.extent
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let local = region?.offsetBy(dx: -extent.minX, dy: -extent.minY)
        let geometry = Self.dodgeBurnGeometry(crop: crop, sourceSize: sourceSize, size: extent.size, region: local)
        let layers = maskCache.layers(for: settings.activeStrokes, geometry: geometry)
        var out = image
        for layer in layers {
            let mask = extent.origin == .zero
                ? layer.image
                : layer.image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            out = GradeKernels.applyDodgeBurn(key: layer.key, mask: mask, to: out)
        }
        return out
    }

    /// A translucent red wash where dodge and burn strokes have been painted.
    func dodgeBurnOverlay(_ settings: DodgeBurnSettings, over image: CIImage, extent: CGRect, crop: CropSettings,
                          sourceSize: CGSize, region: CGRect?) -> CIImage {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let local = region?.offsetBy(dx: -extent.minX, dy: -extent.minY)
        let geometry = Self.dodgeBurnGeometry(crop: crop, sourceSize: sourceSize, size: extent.size, region: local)
        var out = image
        for layer in maskCache.layers(for: settings.activeStrokes, geometry: geometry) {
            let mask = extent.origin == .zero
                ? layer.image
                : layer.image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            let tint = CIFilter.colorMatrix()
            tint.inputImage = mask
            tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            tint.aVector = CIVector(x: Self.overlayOpacity, y: 0, z: 0, w: 0)
            tint.biasVector = CIVector(x: 0.95, y: 0.12, z: 0.1, w: 0)
            guard let wash = tint.outputImage else { continue }
            out = wash.composited(over: out).cropped(to: image.extent)
        }
        return out
    }

    static let overlayOpacity: CGFloat = 0.55

    /// Builds (or updates in the cache) the masks for `settings` on a picture of `size` pixels and returns
    /// how many there are. For benchmarks and warm-ups; rendering does this itself.
    @discardableResult
    public func prepareDodgeBurnMasks(_ settings: DodgeBurnSettings, crop: CropSettings, sourceSize: CGSize,
                                      size: CGSize) -> Int {
        let g = Self.dodgeBurnGeometry(crop: crop, sourceSize: sourceSize, size: size, region: nil)
        return maskCache.layers(for: settings.activeStrokes, geometry: g).count
    }

    /// Rasterises `settings` from scratch without touching the cache (benchmarks).
    public static func rasterizeDodgeBurnMasks(_ settings: DodgeBurnSettings, crop: CropSettings, sourceSize: CGSize,
                                               size: CGSize) -> Int {
        let g = dodgeBurnGeometry(crop: crop, sourceSize: sourceSize, size: size, region: nil)
        return DodgeBurnRaster.rasterize(settings.activeStrokes, geometry: g).order.count
    }
}

/// Where a point of the picture as shown lands on the source, and how big a brush is on it. The
/// editor uses these to turn pointer positions into stroke points and to size the cursor.
public enum DodgeBurnPlacement {
    /// The stroke coordinate (0...1 over the uncropped, upright source, origin top left) for `point`, a
    /// position in the cropped output at full resolution (pixels, origin top left, y down; no border).
    /// Not clamped: a point just outside the picture comes back outside 0...1.
    public static func sourcePoint(forOutputPoint point: CGPoint, crop: CropSettings, sourceSize: CGSize) -> CGPoint? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let extent = CGRect(origin: .zero, size: sourceSize)
        let t = CropGeometry.transform(for: crop, imageExtent: extent)
        guard abs(t.a * t.d - t.b * t.c) > 1e-12 else { return nil }
        let out = CropGeometry.outputExtent(for: crop, imageExtent: extent).size
        let s = CGPoint(x: point.x, y: out.height - point.y).applying(t.inverted())
        return CGPoint(x: s.x / sourceSize.width, y: 1 - s.y / sourceSize.height)
    }

    /// The inverse of `sourcePoint(forOutputPoint:)`.
    public static func outputPoint(forSourcePoint p: CGPoint, crop: CropSettings, sourceSize: CGSize) -> CGPoint {
        let extent = CGRect(origin: .zero, size: sourceSize)
        let t = CropGeometry.transform(for: crop, imageExtent: extent)
        let out = CropGeometry.outputExtent(for: crop, imageExtent: extent).size
        let q = CGPoint(x: p.x * sourceSize.width, y: (1 - p.y) * sourceSize.height).applying(t)
        return CGPoint(x: q.x, y: out.height - q.y)
    }

    /// The brush radius in output pixels at full resolution for a stroke `size`.
    public static func brushRadius(size: Double, crop: CropSettings, sourceSize: CGSize) -> Double {
        let t = CropGeometry.transform(for: crop, imageExtent: CGRect(origin: .zero, size: sourceSize))
        return size * Double(min(sourceSize.width, sourceSize.height)) * Double(hypot(t.a, t.b)) / 2
    }
}
