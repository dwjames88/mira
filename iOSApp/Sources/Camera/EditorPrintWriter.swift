import MiraCamera
import MiraCore
import Photos

/// Step 2 of a camera save: attaches the recipe to the frame already in Photos, with the editor's own save
/// (`AssetEditSession`: reads the original, renders the recipe over it at full size, writes `MiraAdjustment`
/// data). A RAW+HEIC pair is opened on the RAW exactly as the editor does, so the edit is RAW-based.
///
/// Isolation: the work runs on the MAIN actor, because `AssetEditSession` is `@MainActor`. Its heavy parts
/// (RAW develop, render, JPEG encode) already hop to detached tasks, and the print queue drains one frame at a
/// time, so the main actor is only ever held for short stretches between awaits. Plan 4.4 step 6 allows this
/// and a nonisolated split-out later. Nothing here hands a main-actor closure to Photos: PhotoKit calls stay
/// inside `AssetEditSession` / `EditKit`, whose closures are `@Sendable` and built nonisolated.
struct EditorPrintWriter: PrintWriting {
    /// nil when the app bundle has no films: every attach then fails and waits in the queue.
    let renderer: Renderer?

    func attach(recipe: Recipe, toAsset id: String, rawBase: Bool) async throws {
        try await Self.attachOnMain(recipe: recipe, assetID: id, rawBase: rawBase, renderer: renderer)
    }

    @MainActor
    private static func attachOnMain(recipe: Recipe, assetID: String, rawBase: Bool, renderer: Renderer?) async throws {
        guard let renderer else { throw PrintError.failed("Film library missing from the app bundle") }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PrintError.assetMissing
        }
        let session = AssetEditSession(asset: asset)
        let loaded: AssetEditSession.Loaded
        do { loaded = try await session.load() } catch { throw PrintError.failed(error.localizedDescription) }
        // A frame saved with its DNG must print on the RAW; if Photos has not offered the RAW yet, try again later.
        guard loaded.isFullSize, !rawBase || loaded.isRaw else {
            throw PrintError.failed("The original is not ready yet")
        }
        do { try await session.save(recipe: recipe, renderer: renderer) } catch { throw PrintError.failed(error.localizedDescription) }
    }
}
