import CoreImage
import Foundation
import ImageIO

extension ImageSource {
    /// The photo as the recipe wants it developed: a RAW file is decoded with `recipe.raw`
    /// (automatic boost and extended range resolve for `recipe.filmID != nil`), anything else is
    /// loaded normally. Always upright. `draft` is for on-screen previews (fast, reduced size);
    /// export and share pass false. Use this wherever a file is loaded for rendering.
    public static func developedSource(
        url: URL, orientation: CGImagePropertyOrientation? = nil, recipe: Recipe, draft: Bool
    ) -> CIImage? {
        guard isRAW(url: url), let develop = RawDevelop(url: url, orientation: orientation) else {
            return load(url: url, orientation: orientation)
        }
        let scale = draft ? develop.previewScale() : 1
        return develop.apply(recipe.raw, filmApplied: recipe.filmID != nil, draft: draft, scale: scale)
            ?? load(url: url, orientation: orientation)
    }
}
