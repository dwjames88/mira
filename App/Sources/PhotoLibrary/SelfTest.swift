import CoreImage
import EmulsionCore
import Foundation
import OSLog
import Photos

/// Launch-argument self tests (`--selftest-photos`, `--selftest-sidecar`). They only ever touch
/// an asset they import themselves into the "Emulsion Test" album.
enum SelfTest {
    private static let log = Logger(subsystem: "com.dwjames.emulsion", category: "selftest")

    private static func note(_ message: String) {
        log.notice("SELFTEST \(message, privacy: .public)")
    }

    // MARK: Sidecar

    @MainActor
    static func runSidecar() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("emulsion-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let sample = Bundle.main.url(forResource: "sample", withExtension: "jpg", subdirectory: "SelfTest") else {
                note("SIDECAR FAIL sample missing"); return
            }
            let copy = dir.appendingPathComponent("sample.jpg")
            try fm.copyItem(at: sample, to: copy)
            let store = SidecarStore(fallbackDirectory: dir.appendingPathComponent("fallback", isDirectory: true))
            var recipe = Recipe(filmID: "fuji-velvia-50")
            recipe.grainAmount = 0.4
            let location = try store.save(recipe, for: copy)
            note("SIDECAR location=\(location)")
            guard store.load(for: copy) == recipe else { note("SIDECAR FAIL read-back differs"); return }
            try store.remove(for: copy)
            guard store.load(for: copy) == nil, store.location(for: copy) == nil else {
                note("SIDECAR FAIL still present after remove"); return
            }
            note("SIDECAR PASS")
        } catch {
            note("SIDECAR FAIL \(error)")
        }
    }

    // MARK: Photos

    @MainActor
    static func runPhotos(library: FilmLibrary) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized else {
            note("FAIL auth=\(status.rawValue)")
            return
        }
        note("step1 auth ok")

        // 2. Import into the Emulsion Test album.
        guard let sample = Bundle.main.url(forResource: "sample", withExtension: "jpg", subdirectory: "SelfTest") else {
            note("FAIL step2 sample.jpg missing from bundle"); return
        }
        let identifier: String
        do {
            identifier = try await importSample(sample)
        } catch {
            note("FAIL step2 import: \(error)"); return
        }
        note("step2 imported localIdentifier=\(identifier)")

        guard let velvia = library.films.first(where: { $0.id.localizedCaseInsensitiveContains("velvia") }) else {
            note("FAIL step3 no Velvia film"); return
        }
        var recipe = Recipe(filmID: velvia.id)
        recipe.grainAmount = 0.4
        let renderer = Renderer(library: library)

        do {
            // 3. Open, set the recipe, save.
            guard let asset = AssetEditSession.fetchAsset(localIdentifier: identifier) else {
                note("FAIL step3 asset not found"); return
            }
            let session = AssetEditSession(asset: asset)
            let loaded = try await session.load()
            note("step3 opened fullSize=\(loaded.isFullSize) hadOurs=\(loaded.hadOurAdjustments)")
            try await session.save(recipe: recipe, source: loaded.source, renderer: renderer)
            let after = AssetEditSession.fetchAsset(localIdentifier: identifier)
            let edited = after?.hasAdjustments ?? false
            note("step3 saved hasAdjustments=\(edited)")
            guard edited else { note("FAIL step3 hasAdjustments=false"); return }

            // 4. Reopen and compare.
            guard let again = AssetEditSession.fetchAsset(localIdentifier: identifier) else {
                note("FAIL step4 asset not found"); return
            }
            let reopened = try await AssetEditSession(asset: again).load()
            let equal = reopened.hadOurAdjustments && reopened.recipe == recipe
            note("step4 recipe \(equal ? "equal" : "unequal")")
            guard equal else { note("FAIL step4"); return }

            // 5. Revert.
            guard let toRevert = AssetEditSession.fetchAsset(localIdentifier: identifier) else {
                note("FAIL step5 asset not found"); return
            }
            let revertSession = AssetEditSession(asset: toRevert)
            try await revertSession.revert()
            let reverted = AssetEditSession.fetchAsset(localIdentifier: identifier)
            let still = reverted?.hasAdjustments ?? true
            note("step5 reverted hasAdjustments=\(still)")
            guard !still, let finalAsset = reverted else { note("FAIL step5 hasAdjustments"); return }
            let neutral = try await AssetEditSession(asset: finalAsset).load()
            let isNeutral = neutral.recipe == .neutral && !neutral.hadOurAdjustments
            note("step5 reopened recipe \(isNeutral ? "neutral" : "not neutral")")
            guard isNeutral else { note("FAIL step5 reopen"); return }

            note("PASS")
        } catch {
            note("FAIL exception \(error)")
        }
    }

    @MainActor
    private static func importSample(_ url: URL) async throws -> String {
        let title = "Emulsion Test"
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: {
            let o = PHFetchOptions()
            o.predicate = NSPredicate(format: "title = %@", title)
            return o
        }())
        let albumID = existing.firstObject?.localIdentifier
        let box = Unchecked(value: Holder())
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "Emulsion Test Sample.jpg"
            creation.addResource(with: .photo, fileURL: url, options: options)
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            box.value.assetID = placeholder.localIdentifier
            let albumRequest: PHAssetCollectionChangeRequest?
            if let albumID,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
                albumRequest = PHAssetCollectionChangeRequest(for: album)
            } else {
                albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            }
            albumRequest?.addAssets([placeholder] as NSArray)
        }
        guard let id = box.value.assetID else { throw AssetEditError.notSaved("No identifier for the imported asset.") }
        return id
    }

    private final class Holder: @unchecked Sendable { var assetID: String? }
}
