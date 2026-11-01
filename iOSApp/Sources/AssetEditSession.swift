import CoreImage
import ImageIO
import MiraCore
import Photos
import UIKit

enum AssetEditError: Error, LocalizedError {
    case inputUnavailable
    case noFullSizeImage
    case noRenderer

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: "Photos could not provide this picture for editing"
        case .noFullSizeImage: "The full-size picture is not available, so it cannot be saved"
        case .noRenderer: "Film library missing from the app bundle"
        }
    }
}

/// PhotoKit calls made off the main actor. Closures handed to Photos are built in a `nonisolated`
/// context and marked `@Sendable` (Photos calls back on its own queues).
enum EditKit {
    nonisolated static func makeOptions() -> PHContentEditingInputRequestOptions {
        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { @Sendable data in MiraAdjustment.canHandle(data) }
        options.isNetworkAccessAllowed = true
        return options
    }

    nonisolated static func requestEditingInput(asset: Unchecked<PHAsset>) async -> Unchecked<PHContentEditingInput>? {
        let options = Unchecked(value: makeOptions())
        return await withCheckedContinuation { continuation in
            asset.value.requestContentEditingInput(with: options.value) { @Sendable input, _ in
                continuation.resume(returning: input.map(Unchecked.init))
            }
        }
    }

    nonisolated static func saveEdit(asset: Unchecked<PHAsset>, output: Unchecked<PHContentEditingOutput>) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetChangeRequest(for: asset.value)
            request.contentEditingOutput = output.value
        }
    }
}

/// Edits one Photos asset non-destructively: reads our adjustment data, renders a JPEG over the
/// ORIGINAL pixels and hands both to Photos. Asking Photos to "handle" our adjustment data is what
/// makes it return the original base instead of a baked edit. Photos' Revert to Original restores it.
@MainActor
final class AssetEditSession {
    struct Loaded {
        let recipe: Recipe
        let hadOurAdjustments: Bool
        /// Format identifier of adjustments made by another app, if any.
        let foreignFormat: String?
        /// Upright original pixels (or the display-size image when only that was available).
        let source: CIImage
        let colorSpace: CGColorSpace
        let size: CGSize
        let isFullSize: Bool
    }

    private(set) var asset: PHAsset
    private var input: PHContentEditingInput?
    private var source: CIImage?
    private var isFullSize = false

    init(asset: PHAsset) { self.asset = asset }

    func load() async throws -> Loaded {
        let input = try await requestInput()
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
        var space: CGColorSpace?
        var full = false
        if let url = input.fullSizeImageURL {
            let orientation = CGImagePropertyOrientation(rawValue: UInt32(input.fullSizeImageOrientation))
            let loaded = await Task.detached(priority: .userInitiated) { () -> (Unchecked<CIImage>, Unchecked<CGColorSpace>)? in
                guard let image = ImageSource.load(url: url, orientation: orientation) else { return nil }
                return (Unchecked(value: image), Unchecked(value: ImageSource.outputColorSpace(url: url, image: image)))
            }.value
            if let loaded { image = loaded.0.value; space = loaded.1.value; full = true }
        }
        if image == nil, let cg = input.displaySizeImage?.cgImage {
            image = CIImage(cgImage: cg)
        }
        guard let image else { throw AssetEditError.inputUnavailable }
        let colorSpace = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.source = image
        isFullSize = full
        return Loaded(recipe: recipe, hadOurAdjustments: ours, foreignFormat: foreign, source: image,
                      colorSpace: colorSpace, size: image.extent.size, isFullSize: full)
    }

    private func requestInput() async throws -> PHContentEditingInput {
        guard let input = await EditKit.requestEditingInput(asset: Unchecked(value: asset))?.value else {
            throw AssetEditError.inputUnavailable
        }
        return input
    }

    /// Renders `recipe` over the pristine original at full size and commits it as an edit of the asset.
    func save(recipe: Recipe, renderer: Renderer) async throws {
        guard let input, let source else { throw AssetEditError.inputUnavailable }
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

        try await EditKit.saveEdit(asset: Unchecked(value: asset), output: Unchecked(value: output))
        try await refreshAsset()
    }

    /// Re-fetches the asset (its version changed) and a fresh editing input so a later save works.
    private func refreshAsset() async throws {
        if let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject {
            asset = fresh
        }
        input = try await requestInput()
    }
}
