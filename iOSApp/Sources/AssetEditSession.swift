import CoreImage
import ImageIO
import MiraCore
import MiraUI
import Photos
import UIKit

enum AssetEditError: Error, LocalizedError {
    case inputUnavailable
    case photosDidNotDeliver
    case noFullSizeImage
    case noRenderer
    case rawOriginalMissing

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: "Photos could not provide this picture for editing"
        case .photosDidNotDeliver: FFOpenFailureCard.defaultMessage
        case .noFullSizeImage: "The full-size picture is not available, so it cannot be saved"
        case .noRenderer: "Film library missing from the app bundle"
        case .rawOriginalMissing: "This edit was made on the RAW original, which Photos could not provide. Check the connection to iCloud and try again"
        }
    }
}

/// PhotoKit calls made off the main actor. Closures handed to Photos are built in a `nonisolated`
/// context and marked `@Sendable` (Photos calls back on its own queues).
enum EditKit {
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
        /// True when `source` is a draft develop of the RAW original (see `rawSource(for:full:)` for the full-quality one).
        let isRaw: Bool
        /// Why the rendered picture opened although the asset has a RAW, for the status line.
        let rawNote: String?
    }

    private(set) var asset: PHAsset
    private var input: PHContentEditingInput?
    private var source: CIImage?
    private var isFullSize = false
    /// The RAW being developed (the editing input's own file, or the asset's RAW resource).
    private var rawDevelop: RawDevelop?
    private var rawURL: URL?
    /// True when the RAW is a separately fetched resource: saved edits are marked as RAW-based.
    private var rawIsFetched = false

    /// What the Develop panel needs of the RAW being developed: its as-shot white balance and the controls its decoder supports.
    var rawInfo: (asShot: (temperature: Double, tint: Double), supported: RawSupportedControls)? {
        rawDevelop.map { ($0.asShot, $0.supported) }
    }

    private let policy: EditingInputPolicy
    private let makeRequester: @Sendable (PHAsset) -> any EditingInputRequesting<PHContentEditingInput>

    init(asset: PHAsset, policy: EditingInputPolicy = .standard,
         makeRequester: @escaping @Sendable (PHAsset) -> any EditingInputRequesting<PHContentEditingInput> = { PhotoKitEditingInputRequester(asset: $0) }) {
        self.asset = asset
        self.policy = policy
        self.makeRequester = makeRequester
    }

    func load(onEvent: @escaping @Sendable (EditingInputEvent) -> Void = { _ in }) async throws -> Loaded {
        let input = try await requestInput(onEvent: onEvent)
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
        var rawNote: String?
        rawDevelop = nil; rawURL = nil; rawIsFetched = false

        let inputURL = input.fullSizeImageURL
        let inputOrientation = CGImagePropertyOrientation(rawValue: UInt32(input.fullSizeImageOrientation))
        let inputIsRAW = inputURL.map { ImageSource.isRAW(url: $0) } ?? false
        let id = asset.localIdentifier
        let hasRawResource = inputIsRAW ? true : await Task.detached(priority: .userInitiated) {
            RawResourceStore.rawResource(forAsset: id) != nil
        }.value
        let adjustments = MiraAdjustment.state(of: input.adjustmentData)
        let plan = RawOpenPolicy.plan(inputIsRAW: inputIsRAW, adjustments: adjustments, hasRawResource: hasRawResource)

        var rawSource: (url: URL, orientation: CGImagePropertyOrientation?)?
        switch plan {
        case .useInput:
            if let inputURL { rawSource = (inputURL, inputOrientation) }
        case .fetchResource:
            do {
                // The RAW has its own orientation metadata; fullSizeImageOrientation describes the rendered file.
                rawSource = (try await RawResourceStore.fetchRaw(forAsset: id), nil)
                rawIsFetched = true
            } catch {
                if case .mira(rawBase: true) = adjustments { throw AssetEditError.rawOriginalMissing }
                rawNote = "RAW NOT DOWNLOADED · OPENED THE RENDERED PICTURE"
            }
        case .rawBaseMissing:
            throw AssetEditError.rawOriginalMissing
        case .keepRendered(let reason):
            if reason == .foreignAdjustments { rawNote = "EDITED IN ANOTHER APP · OPENED THE RENDERED PICTURE, NOT THE RAW" }
            if reason == .earlierEditOnRenderedFile { rawNote = "EARLIER EDIT KEEPS ITS RENDERED BASE" }
        }

        if let raw = rawSource {
            // Draft develop at preview size (cached per asset for the session) is the first editable frame; the
            // view model swaps in the full-quality develop in the background.
            let developRecipe = recipe
            let frame = await Task.detached(priority: .userInitiated) {
                RawOpener.openDraft(url: raw.url, orientation: raw.orientation, settings: developRecipe.raw,
                                    filmApplied: developRecipe.filmID != nil, cacheKey: id)
            }.value
            if let frame {
                image = frame.source.image
                space = ImageSource.outputColorSpace(url: raw.url, image: frame.source.image)
                full = true
                rawDevelop = frame.develop
                rawURL = raw.url
            }
        } else if let url = inputURL {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (Unchecked<CIImage>, Unchecked<CGColorSpace>)? in
                guard let image = ImageSource.load(url: url, orientation: inputOrientation) else { return nil }
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
                      colorSpace: colorSpace, size: image.extent.size, isFullSize: full,
                      isRaw: rawDevelop != nil, rawNote: rawNote)
    }

    /// The RAW developed for `recipe`'s RAW settings: draft at preview size, or (`full`) the full-quality
    /// full-size develop that zoom, histogram and Save use. nil for non-RAW assets. Runs off the main actor.
    func rawSource(for recipe: Recipe, full: Bool) async -> LoadedSource? {
        guard let develop = rawDevelop, let url = rawURL else { return nil }
        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedSource? in
            let developed = develop.develop(recipe.raw, filmApplied: recipe.filmID != nil, draft: !full,
                                            scale: full ? 1 : develop.previewScale())
            guard let image = developed?.image else { return nil }
            return LoadedSource(image: image, colorSpace: ImageSource.outputColorSpace(url: url, image: image),
                                size: image.extent.size)
        }.value
        if full, let loaded { source = loaded.image }
        return loaded
    }

    private func requestInput(onEvent: @escaping @Sendable (EditingInputEvent) -> Void = { _ in }) async throws -> PHContentEditingInput {
        let requester = makeRequester(asset)
        do {
            return try await EditingInputFetch.fetch(requester, policy: policy, onEvent: onEvent)
        } catch {
            switch error {
            case .timedOut: throw AssetEditError.photosDidNotDeliver
            case .unavailable: throw AssetEditError.inputUnavailable
            case .cancelled: throw CancellationError()
            }
        }
    }

    /// Renders `recipe` over the pristine original at full size and commits it as an edit of the asset.
    func save(recipe: Recipe, renderer: Renderer) async throws {
        guard let input, var source else { throw AssetEditError.inputUnavailable }
        guard isFullSize, let inputURL = input.fullSizeImageURL else { throw AssetEditError.noFullSizeImage }

        // A RAW is developed again, full quality and full size, for the recipe being saved.
        if rawDevelop != nil {
            guard let full = await rawSource(for: recipe, full: true) else { throw AssetEditError.inputUnavailable }
            source = full.image
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        // An edit made on a separately fetched RAW says so, so it reopens on the RAW and the Photos extension
        // (which only receives the rendered JPEG of a pair) leaves it alone.
        output.adjustmentData = try MiraAdjustment.adjustmentData(for: recipe, rawBase: rawIsFetched)
        let outputURL = output.renderedContentURL
        let colorSpace = ImageSource.outputColorSpace(url: rawURL ?? inputURL, image: source)

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
