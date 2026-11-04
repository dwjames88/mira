import CoreImage
import Foundation

/// How much of a frame falls outside the film's recording range (see `Renderer.latitudeReading`).
public struct LatitudeReading: Sendable, Equatable {
    /// Fraction of pixels darker than the film's under-exposure limit (0...1).
    public var under: Double
    /// Fraction of pixels brighter than the film's over-exposure limit (0...1).
    public var over: Double
    /// Stops by which the darkest 1% of the frame is below the limit (0 when inside the range).
    public var underStops: Double
    /// Stops by which the brightest 1% of the frame is above the limit (0 when inside the range).
    public var overStops: Double

    public init(under: Double, over: Double, underStops: Double, overStops: Double) {
        self.under = under
        self.over = over
        self.underStops = underStops
        self.overStops = overStops
    }
}

extension Renderer {
    /// Measures the frame against the selected film's latitude: luma relative to 18% gray, on the
    /// linear image the film sees (after crop, exposure and push gain WITHOUT the latitude shoulder,
    /// white balance, dodge and burn, colour mixer and curves). A pixel is under when its luma is
    /// below `0.18 * 2^-latitudeUnder` and over when above `0.18 * 2^latitudeOver`.
    ///
    /// Cheap (one render of at most 256 px on the long side) and safe to call from any thread.
    /// nil when the recipe has no film.
    public func latitudeReading(_ recipe: Recipe, input: CIImage, context: CIContext) -> LatitudeReading? {
        guard let id = recipe.filmID, let film = library.film(id: id) else { return nil }
        let character = film.resolvedCharacter
        let source = input.extent
        guard !source.isInfinite, !source.isEmpty else { return nil }

        // Shrink the source so the cropped result is about 256 px, then crop that.
        let cropped = CropGeometry.apply(recipe.crop, to: input).extent.size
        let factor = min(1, 256 / max(cropped.width, cropped.height, 1))
        var small = input
        if factor < 1 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = input
            f.scale = Float(factor)
            f.aspectRatio = 1
            small = f.outputImage ?? input
        }
        small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        var image = CropGeometry.apply(recipe.crop, to: small)
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }

        let push = recipe.pipeline >= 2 ? min(max(recipe.push, -2), 2) : 0
        let ev = min(max(recipe.exposure, -2), 2) + 0.33 * push
        if abs(ev) > 1e-6 { image = GradeKernels.applyFilmExposure(gain: exp2(ev), latitude: 0, to: image) }
        image = whiteBalanceForMeter(image, recipe)
        if recipe.dodgeBurn.hasVisibleEffect {
            image = applyDodgeBurn(recipe.dodgeBurn, to: image, crop: recipe.crop, sourceSize: small.extent.size, region: nil)
        }
        if !recipe.colorMixer.isIdentity { image = GradeKernels.applyColorMixer(recipe.colorMixer, to: image) }
        if !recipe.curves.isIdentity { image = GradeKernels.applyCurves(recipe.curves, to: image) }

        let w = Int(extent.width), h = Int(extent.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &buffer, rowBytes: w * 16, bounds: extent, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var lumas = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            lumas[i] = 0.2126 * Double(buffer[i * 4]) + 0.7152 * Double(buffer[i * 4 + 1]) + 0.0722 * Double(buffer[i * 4 + 2])
        }
        let low = 0.18 * exp2(-character.latitudeUnder), high = 0.18 * exp2(character.latitudeOver)
        let n = Double(lumas.count)
        let under = Double(lumas.filter { $0 < low }.count) / n
        let over = Double(lumas.filter { $0 > high }.count) / n
        lumas.sort()
        let p01 = max(lumas[Int(n * 0.01)], 1e-6), p99 = max(lumas[min(lumas.count - 1, Int(n * 0.99))], 1e-6)
        return LatitudeReading(under: under, over: over,
                               underStops: max(0, log2(low / p01)), overStops: max(0, log2(p99 / high)))
    }
}
