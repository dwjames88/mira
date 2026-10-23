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
}
