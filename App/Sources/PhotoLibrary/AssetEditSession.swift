import AppKit
import CoreImage
import MiraCore
import MiraUI
import ImageIO
import Photos

/// Carries a non-Sendable PhotoKit / Core Image value across an isolation boundary. Used sparingly:
/// the wrapped values are only touched by one task at a time.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

enum AssetEditError: Error, CustomStringConvertible {
    case inputUnavailable
    case photosDidNotDeliver
    case noFullSizeImage
    case rawOriginalMissing
    case notSaved(String)

    var description: String {
        switch self {
        case .inputUnavailable: "Photos could not provide this picture for editing."
        case .photosDidNotDeliver: FFOpenFailureCard.defaultMessage
        case .noFullSizeImage: "The full-size picture is not available, so it cannot be saved."
        case .rawOriginalMissing: "This edit was made on the RAW original, which Photos could not provide. Check the connection to iCloud and try again."
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
        /// The decoder opened for `rawURL` (cached for the session); hand it to `attachRawSource`.
        let rawDevelop: RawDevelop?
        /// Why the picture opened from the rendered file although the asset has a RAW; shown in the editor note.
        let rawNote: String?
    }

    private(set) var asset: PHAsset
    private var input: PHContentEditingInput?
    private var isFullSize = false
    /// The RAW original downloaded as a separate resource (RAW+JPEG pairs, or a RAW whose editing input is
    /// the rendered file). The editing input stays the base of the saved output; this file is what is developed.
    private var fetchedRawURL: URL?

    var localIdentifier: String { asset.localIdentifier }
    var fullSizeURL: URL? { input?.fullSizeImageURL }

    /// True for assets opened from Recently Deleted: viewable, never saved or reverted.
    let isReadOnly: Bool

    private let policy: EditingInputPolicy
    private let makeRequester: @Sendable (PHAsset) -> any EditingInputRequesting<PHContentEditingInput>

    init(asset: PHAsset, isReadOnly: Bool = false, policy: EditingInputPolicy = .standard,
         makeRequester: @escaping @Sendable (PHAsset) -> any EditingInputRequesting<PHContentEditingInput> = { PhotoKitEditingInputRequester(asset: $0) }) {
        self.asset = asset
        self.isReadOnly = isReadOnly
        self.policy = policy
        self.makeRequester = makeRequester
    }

    // MARK: Open

    /// Requests the editing input and decodes the source and recipe.
    /// `onEvent` reports `.downloading` and `.retrying` while Photos is asked for the editing input.
    func load(progress: (@MainActor (Double) -> Void)? = nil,
              onEvent: (@MainActor (EditingInputEvent) -> Void)? = nil) async throws -> Loaded {
        let input = try await requestInput(progress: progress, onEvent: onEvent)
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
        var rawDevelop: RawDevelop?
        var rawNote: String?
        fetchedRawURL = nil

        let inputURL = input.fullSizeImageURL
        let inputOrientation = CGImagePropertyOrientation(rawValue: UInt32(input.fullSizeImageOrientation))
        let inputIsRAW = inputURL.map { ImageSource.isRAW(url: $0) } ?? false
        let id = asset.localIdentifier
        // Does the asset carry a RAW original? (A PhotoKit lookup, so off the main actor.)
        let hasRawResource = inputIsRAW ? true : await Task.detached(priority: .userInitiated) {
            RawResourceStore.rawResource(forAsset: id) != nil
        }.value
        let adjustments = MiraAdjustment.state(of: input.adjustmentData)
        let plan = RawOpenPolicy.plan(inputIsRAW: inputIsRAW, adjustments: adjustments, hasRawResource: hasRawResource)

        // Where the RAW comes from: the editing input itself, or the asset's RAW resource.
        var rawSource: (url: URL, orientation: CGImagePropertyOrientation?)?
        switch plan {
        case .useInput:
            if let inputURL { rawSource = (inputURL, inputOrientation) }
        case .fetchResource:
            let handler: (@Sendable (Double) -> Void)? = progress.map { progress in
                { @Sendable value in Task { @MainActor in progress(value) } }
            }
            do {
                // The RAW has its own orientation metadata; Photos' fullSizeImageOrientation describes the rendered file.
                rawSource = (try await RawResourceStore.fetchRaw(forAsset: id, progress: handler), nil)
                fetchedRawURL = rawSource?.url
            } catch {
                if case .mira(rawBase: true) = adjustments { throw AssetEditError.rawOriginalMissing }
                rawNote = "The RAW original could not be downloaded, so the rendered picture was opened."
            }
        case .rawBaseMissing:
            throw AssetEditError.rawOriginalMissing
        case .keepRendered(let reason):
            switch reason {
            case .foreignAdjustments:
                rawNote = "This picture was edited in another app; Photos provides the rendered result, not the RAW, so that is what opens."
            case .earlierEditOnRenderedFile:
                rawNote = "This edit was made on the rendered picture, so it keeps that base instead of the RAW."
            case .noRaw: break
            }
        }

        if let raw = rawSource {
            // RAW: the draft develop at preview size is the first editable frame; the editor replaces it with the
            // full-quality decode in the background. Cached per asset for the session.
            let developRecipe = recipe
            let frame = await Task.detached(priority: .userInitiated) {
                RawOpener.openDraft(url: raw.url, orientation: raw.orientation, settings: developRecipe.raw,
                                    filmApplied: developRecipe.filmID != nil, cacheKey: id)
            }.value
            if let frame {
                image = frame.source.image
                full = true
                rawURL = raw.url; rawOrientation = raw.orientation; rawDevelop = frame.develop
            }
        } else if let url = inputURL {
            let developRecipe = recipe
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageSource.developedSource(url: url, orientation: inputOrientation, recipe: developRecipe, draft: true)
                    .map(Unchecked.init)
            }.value
            if let loaded {
                image = loaded.value
                full = true
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
                      source: image, isFullSize: full, rawURL: rawURL, rawOrientation: rawOrientation,
                      rawDevelop: rawDevelop, rawNote: rawNote)
    }

    /// Goes through `EditingInputFetch`, so a request Photos never answers times out, retries once and then
    /// fails with `.photosDidNotDeliver` instead of hanging.
    private func requestInput(progress: (@MainActor (Double) -> Void)?,
                              onEvent: (@MainActor (EditingInputEvent) -> Void)?) async throws -> PHContentEditingInput {
        let requester = makeRequester(asset)
        let handler: @Sendable (EditingInputEvent) -> Void = { event in
            Task { @MainActor in
                if case .downloading(let p) = event { progress?(p) }
                onEvent?(event)
            }
        }
        do {
            return try await EditingInputFetch.fetch(requester, policy: policy, onEvent: handler)
        } catch {
            switch error {
            case .timedOut: throw AssetEditError.photosDidNotDeliver
            case .unavailable: throw AssetEditError.inputUnavailable
            case .cancelled: throw CancellationError()
            }
        }
    }

    // MARK: Save

    /// Renders `recipe` over `source` at full size and saves it to Photos as an edit of the asset.
    func save(recipe: Recipe, source: CIImage, renderer: Renderer) async throws {
        guard let input else { throw AssetEditError.inputUnavailable }
        guard isFullSize, let inputURL = input.fullSizeImageURL else { throw AssetEditError.noFullSizeImage }

        let output = PHContentEditingOutput(contentEditingInput: input)
        // An edit made on a separately fetched RAW says so, so it reopens on the RAW (and the Photos extension,
        // which only receives the rendered JPEG of a pair, leaves it alone).
        output.adjustmentData = try MiraAdjustment.adjustmentData(for: recipe, rawBase: fetchedRawURL != nil)
        let outputURL = output.renderedContentURL
        // The rendered output is upright pixels in the colour space of what was developed (P3 for RAW). Metadata
        // comes from the editing input, which is the file Photos described (orientation is reset to 1).
        let colorSpace = ImageSource.outputColorSpace(url: fetchedRawURL ?? inputURL, image: source)

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
        if input != nil { input = try await requestInput(progress: nil, onEvent: nil) }
    }

    static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }
}
