import CoreGraphics
import CoreImage
import Foundation

extension PreviewEngine {
    /// Renders one tiny frame through every stage (film, tone, colour, mixer, curves, halation,
    /// bloom, grain, vignette) on the shared context, so Metal shader compilation and Core Image's
    /// kernel setup happen at launch in the background instead of during the first real frame.
    /// Safe to call from any thread; the output is discarded.
    public static func warmUp(library: FilmLibrary) {
        let engine = PreviewEngine(renderer: Renderer(library: library), context: Renderer.sharedContext)
        let size = CGSize(width: 96, height: 64)
        let seed = CIImage(color: CIColor(red: 0.45, green: 0.4, blue: 0.35)).cropped(to: CGRect(origin: .zero, size: size))
        engine.setSource(seed)
        var recipe = Recipe(filmID: library.films.first?.id, exposure: 0.1, contrast: 0.1, saturation: 0.1,
                            warmth: 0.1, tint: 0.1, grainAmount: 0.3, halationAmount: 0.3, bloomAmount: 0.2,
                            vignetteAmount: 0.2)
        recipe.colorMixer.orange = ColorAdjust(hue: 0.1, saturation: 0.1, luminance: 0.1)
        recipe.curves.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        _ = engine.render(recipe, canvas: size)
    }
}
