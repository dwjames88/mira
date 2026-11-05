import AppKit
import CoreImage
import MiraCore
import ImageIO
import Photos

/// Carries a non-Sendable PhotoKit / Core Image value across an isolation boundary. Used sparingly:
/// the wrapped values are only touched by one task at a time.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

enum AssetEditError: Error, CustomStringConvertible {
    case inputUnavailable
    case noFullSizeImage
    case notSaved(String)

    var description: String {
        switch self {
        case .inputUnavailable: "Photos could not provide this picture for editing."
        case .noFullSizeImage: "The full-size picture is not available, so it cannot be saved."
        case .notSaved(let why): why
        }
    }
}

/// Edits one Photos asset non-destructively: reads our adjustment data, renders a JPEG and hands
/// both to Photos. The original is never touched; Photos' "Revert to Original" restores it.
@MainActor
final class AssetEditSession {
    struct Loaded {
        /// The recipe restored from our adjustment data, or neutral.
        let recipe: Recipe
        /// True when the asset carries our adjustment data.
        let hadOurAdjustments: Bool
        /// Format identifier of adjustments made by another app, if any.
        let foreignFormat: String?
        /// Full-size, upright source (or the display-size image when only that was available).
        let source: CIImage
        let isFullSize: Bool
        /// Set when the editing input is a camera RAW file (the source is a draft develop of it);
        /// the editor attaches it with `EditorModel.attachRawSource`.
        let rawURL: URL?
        let rawOrientation: CGImagePropertyOrientation?
    }

    private(set) var asset: PHAsset
    private var input: PHContentEditingInput?
    private var isFullSize = false

    var localIdentifier: String { asset.localIdentifier }
    var fullSizeURL: URL? { input?.fullSizeImageURL }

    /// True for assets opened from Recently Deleted: viewable, never saved or reverted.
    let isReadOnly: Bool

    init(asset: PHAsset, isReadOnly: Bool = false) {
        self.asset = asset
        self.isReadOnly = isReadOnly
    }

    // MARK: Open

    /// Requests the editing input and decodes the source and recipe.
    func load(progress: (@MainActor (Double) -> Void)? = nil) async throws -> Loaded {
        let input = try await requestInput(progress: progress)
        self.input = input

        var recipe = Recipe.neutral
        var ours = false
        var foreign: String?
        if let data = input.adjustmentData {
            if let decoded = MiraAdjustment.recipe(from: data) {
                recipe = decoded
                ours = true
            } else {
                foreign = data.formatIdentifier
            }
        }

        var image: CIImage?
        var full = false
        var rawURL: URL?
        var rawOrientation: CGImagePropertyOrientation?
        if let url = input.fullSizeImageURL {
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(input.fullSizeImageOrientation))
            // RAW input is developed with the saved recipe's RAW settings (draft: this is the preview).
            let developRecipe = recipe
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageSource.developedSource(url: url, orientation: orientation, recipe: developRecipe, draft: true)
                    .map(Unchecked.init)
            }.value
            if let loaded {
                image = loaded.value
                full = true
                if ImageSource.isRAW(url: url) { rawURL = url; rawOrientation = orientation }
            }
        }
        if image == nil, let cg = input.displaySizeImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // The stand-in carries no EXIF; the exposure time (reciprocity) comes from the original's file.
            image = CIImage(cgImage: cg)
                .withMiraExposureTime(input.fullSizeImageURL.flatMap { ImageSource.exposureTime(url: $0) })
        }
        guard let image else { throw AssetEditError.inputUnavailable }
        isFullSize = full
        return Loaded(recipe: recipe, hadOurAdjustments: ours, foreignFormat: foreign,
                      source: image, isFullSize: full, rawURL: rawURL, rawOrientation: rawOrientation)
    }

    private func requestInput(progress: (@MainActor (Double) -> Void)?) async throws -> PHContentEditingInput {
        let handler: (@Sendable (Double) -> Void)? = progress.map { progress in
            { @Sendable value in Task { @MainActor in progress(value) } }
        }
        let result = await PhotoKitBridge.requestEditingInput(asset: Unchecked(value: asset), progress: handler)
        guard let input = result?.value else { throw AssetEditError.inputUnavailable }
        return input
    }

    // MARK: Save

    /// Renders `recipe` over `source` at full size and saves it to Photos as an edit of the asset.
    func save(recipe: Recipe, source: CIImage, renderer: Renderer) async throws {
        guard let input else { throw AssetEditError.inputUnavailable }
        guard isFullSize, let inputURL = input.fullSizeImageURL else { throw AssetEditError.noFullSizeImage }

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = try MiraAdjustment.adjustmentData(for: recipe)
        let outputURL = output.renderedContentURL
        let colorSpace = ImageSource.outputColorSpace(url: inputURL, image: source)

        let sourceBox = Unchecked(value: source)
        try await Task.detached(priority: .userInitiated) {
            try renderer.export(recipe, source: sourceBox.value, metadataFrom: inputURL,
                                outputURL: outputURL, type: .jpeg, quality: 0.95, colorSpace: colorSpace)
        }.value

        let assetBox = Unchecked(value: asset)
        let outputBox = Unchecked(value: output)
        try await PhotoKitBridge.saveEdit(asset: assetBox, output: outputBox)
        try await refreshAsset()
    }

    // MARK: Revert

    func revert() async throws {
        let assetBox = Unchecked(value: asset)
        try await PhotoKitBridge.revert(asset: assetBox)
        try await refreshAsset()
        input = nil
    }

    /// Re-fetches the asset (its version changed) and, after a save, a fresh editing input.
    private func refreshAsset() async throws {
        if let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject {
            asset = fresh
        }
        if input != nil { input = try await requestInput(progress: nil) }
    }

    static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }
}
