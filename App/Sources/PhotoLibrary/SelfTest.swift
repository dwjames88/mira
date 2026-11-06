import CoreImage
import MiraCore
import Foundation
import OSLog
import Photos

/// Launch-argument self tests (`--selftest-photos`, `--selftest-sidecar`). They only ever touch
/// an asset they import themselves into the "Emulsion Test" album.
/// The album keeps its pre-rename name on purpose so every test asset stays in one album
/// (created before the rename) that can be deleted in one go.
enum SelfTest {
    private static let log = Logger(subsystem: "com.fieldframes.mira", category: "selftest")

    private static func note(_ message: String) {
        log.notice("SELFTEST \(message, privacy: .public)")
    }

    // MARK: Sidecar

    @MainActor
    static func runSidecar() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mira-selftest-\(UUID().uuidString)", isDirectory: true)
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
    static func runPhotos(library: FilmLibrary, allowDelete: Bool = false) async {
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

            guard await libraryRoundTrip(identifier: identifier, allowDelete: allowDelete) else { return }

            note("PASS")
        } catch {
            note("FAIL exception \(error)")
        }
    }

    // MARK: Library round trip

    // Plain fetches by title and id: `userAlbums()` counts the pictures of every album, slow on a big library.
    private static func albumID(titled title: String) -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject?.localIdentifier
    }

    private static func albumTitle(id: String) -> String? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject?.localizedTitle
    }

    /// Finds the album by title or creates it.
    private static func ensureAlbum(_ title: String) async throws -> String {
        if let id = albumID(titled: title) { return id }
        return try await LibraryActions.createAlbum(title: title)
    }

    /// Steps 6 to 9 on the asset the self test imported: favorite, albums (add, move, remove, rename),
    /// hide, duplicate. Hiding, deleting the duplicate and deleting the scratch albums raise Photos' confirmation
    /// alert (a person must click it), so those parts run only with `--selftest-photos-delete`.
    private static func libraryRoundTrip(identifier: String, allowDelete: Bool) async -> Bool {
        func verdict(_ step: String, _ ok: Bool, _ detail: String = "") -> Bool {
            note(ok ? "\(step) PASS \(detail)" : "FAIL \(step) \(detail)")
            return ok
        }
        do {
            // 6. Favorite on, verify, off.
            try await LibraryActions.setFavorite([identifier], true)
            guard verdict("step6 favorite on", LibraryActions.isFavorite(id: identifier) == true) else { return false }
            try await LibraryActions.setFavorite([identifier], false)
            guard verdict("step6 favorite off", LibraryActions.isFavorite(id: identifier) == false) else { return false }

            // 7. Albums: add, move, remove, rename and back.
            let scratch = try await ensureAlbum("Emulsion Test Scratch")
            let scratch2 = try await ensureAlbum("Emulsion Test Scratch 2")
            note("step7 albums scratch=\(scratch) scratch2=\(scratch2)")
            try await LibraryActions.add([identifier], toAlbum: scratch)
            guard verdict("step7 add", LibraryActions.albumIDs(containing: identifier).contains(scratch)) else { return false }
            try await LibraryActions.move([identifier], from: scratch, to: scratch2)
            let afterMove = LibraryActions.albumIDs(containing: identifier)
            guard verdict("step7 move", afterMove.contains(scratch2) && !afterMove.contains(scratch)) else { return false }
            try await LibraryActions.remove([identifier], fromAlbum: scratch2)
            let afterRemove = LibraryActions.albumIDs(containing: identifier)
            guard verdict("step7 remove", !afterRemove.contains(scratch2) && !afterRemove.contains(scratch)) else { return false }
            try await LibraryActions.renameAlbum(id: scratch2, title: "Emulsion Test Scratch B")
            guard verdict("step7 rename", albumTitle(id: scratch2) == "Emulsion Test Scratch B") else { return false }
            try await LibraryActions.renameAlbum(id: scratch2, title: "Emulsion Test Scratch 2")
            guard verdict("step7 rename back", albumTitle(id: scratch2) == "Emulsion Test Scratch 2") else { return false }

            // 8. Hide, verify, unhide. Photos asks the user to confirm hiding (a system alert), so like
            // deletion it runs only with `--selftest-photos-delete`.
            if allowDelete {
                try await LibraryActions.setHidden([identifier], true)
                guard verdict("step8 hide", LibraryStore.flags(for: [identifier]).allHidden) else { return false }
                try await LibraryActions.setHidden([identifier], false)
                guard verdict("step8 unhide", !LibraryStore.flags(for: [identifier]).allHidden) else { return false }
            } else {
                note("step8 hide SKIPPED (Photos shows a confirmation alert; pass --selftest-photos-delete to run it)")
            }

            // 9. Duplicate: a new asset in no album; then put it in "Emulsion Test" so it is cleaned with the album.
            let copies = try await LibraryActions.duplicate([identifier])
            guard let copy = copies.first, copy != identifier else { return verdict("step9 duplicate", false, "no new id") }
            let exists = PHAsset.fetchAssets(withLocalIdentifiers: [copy], options: nil).count == 1
            let noAlbums = LibraryActions.albumIDs(containing: copy).isEmpty
            guard verdict("step9 duplicate", exists && noAlbums, "copy=\(copy) exists=\(exists) inNoAlbum=\(noAlbums)") else { return false }
            guard let testAlbum = albumID(titled: "Emulsion Test") else { return verdict("step9 test album", false, "Emulsion Test album missing") }
            try await LibraryActions.add([copy], toAlbum: testAlbum)
            guard verdict("step9 copy added to Emulsion Test", LibraryActions.albumIDs(containing: copy).contains(testAlbum)) else { return false }

            guard allowDelete else {
                note("step9 delete SKIPPED (pass --selftest-photos-delete; Photos asks for a click). Scratch albums and the duplicate remain; both live in or beside Emulsion Test.")
                return true
            }
            try await LibraryActions.delete([copy])
            guard verdict("step9 delete duplicate", true, "request completed") else { return false }
            try await LibraryActions.deleteAlbum(id: scratch)
            try await LibraryActions.deleteAlbum(id: scratch2)
            return verdict("step9 delete scratch albums", albumID(titled: "Emulsion Test Scratch") == nil && albumID(titled: "Emulsion Test Scratch 2") == nil)
        } catch {
            if LibraryActions.isUserCancel(error) { note("step9 delete cancelled by the user") ; return true }
            note("FAIL library round trip: \(error)")
            return false
        }
    }

    private static func importSample(_ url: URL) async throws -> String {
        let id = try await PhotoKitBridge.importPhoto(url: url, filename: "Emulsion Test Sample.jpg", albumTitle: "Emulsion Test")
        guard let id else { throw AssetEditError.notSaved("No identifier for the imported asset.") }
        return id
    }
}
