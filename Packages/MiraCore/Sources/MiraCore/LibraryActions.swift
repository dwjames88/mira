import CoreLocation
import Foundation
import Photos

/// Why a library operation was refused before (or instead of) reaching Photos.
public enum LibraryActionError: Error, LocalizedError, Equatable, Sendable {
    /// An asset or album with that identifier is gone (or not visible to a limited-access app).
    case notFound
    /// Photos does not allow the operation here (the string says what, e.g. "This album can't take photos.").
    case notAllowed(String)
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .notFound: "That photo or album is no longer in your library."
        case .notAllowed(let reason): reason
        case .emptyTitle: "Give the album a name."
        }
    }
}

/// Photos-library operations shared by the iOS and Mac apps.
///
/// Everything takes and returns local-identifier strings; the PHAsset / PHAssetCollection objects are
/// fetched inside each call, so nothing non-Sendable crosses the boundary. Every `performChanges`
/// block is built in this `nonisolated` context and marked `@Sendable`: a closure written in
/// `@MainActor` code inherits main-actor isolation and traps in Swift 6's executor check when Photos
/// calls it on its own queue. Call these from anywhere; the writes are `async throws`, the reads are
/// synchronous and safe off the main actor.
///
/// Photos shows its own confirmation for deletions; a user "Cancel" there surfaces as an error. Swallow
/// it with `isUserCancel`.
public enum LibraryActions {
    // MARK: Asset flags

    public nonisolated static func setFavorite(_ ids: [String], _ on: Bool) async throws {
        guard !ids.isEmpty else { return }
        try requireAssets(ids)
        try await perform { @Sendable in
            for asset in assetList(ids) { PHAssetChangeRequest(for: asset).isFavorite = on }
        }
    }

    public nonisolated static func setHidden(_ ids: [String], _ on: Bool) async throws {
        guard !ids.isEmpty else { return }
        try requireAssets(ids)
        try await perform { @Sendable in
            for asset in assetList(ids) { PHAssetChangeRequest(for: asset).isHidden = on }
        }
    }

    /// Moves the assets to Recently Deleted (Photos asks the user to confirm; see `isUserCancel`).
    public nonisolated static func delete(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try requireAssets(ids)
        try await perform { @Sendable in
            PHAssetChangeRequest.deleteAssets(nsArray(fetchAssets(ids)))
        }
    }

    /// True when the error is the user dismissing Photos' own confirmation (PHPhotosError.userCancelled,
    /// or NSCocoaErrorDomain 3072). UIs should swallow it.
    public nonisolated static func isUserCancel(_ error: Error) -> Bool {
        if let photos = error as? PHPhotosError, photos.code == .userCancelled { return true }
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.userCancelled.rawValue { return true }
        return ns.domain == NSCocoaErrorDomain && ns.code == 3072
    }

    // MARK: Duplicate

    /// Duplicates photos and returns the new local identifiers (same order, skipping assets that could
    /// not be read).
    ///
    /// Photos has no duplication API in the SDK (no `PHAssetChangeRequest` duplicate), so each asset's
    /// current picture is written to a temporary file with `PHAssetResourceManager` (iCloud originals
    /// are downloaded) and imported with `PHAssetCreationRequest`, keeping creation date, location and
    /// favorite. The copy is what you see: an edited photo's rendered full-size image (flattened, no
    /// adjustment data, so the copy cannot be reverted); an unedited one keeps its original resources
    /// (a RAW+JPEG pair stays a pair). Videos and Live Photo motion are not copied.
    public nonisolated static func duplicate(_ ids: [String]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        try requireAssets(ids)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var plans: [DuplicatePlan] = []
        for (index, id) in ids.enumerated() {
            guard let asset = fetchAssets([id]).firstObject else { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            var chosen: [(resource: PHAssetResource, type: PHAssetResourceType, filename: String)] = []
            let original = resources.first { $0.type == .photo } ?? resources.first { $0.type == .alternatePhoto }
            if let full = resources.first(where: { $0.type == .fullSizePhoto }), let original {
                let base = (original.originalFilename as NSString).deletingPathExtension
                let ext = (full.originalFilename as NSString).pathExtension
                chosen = [(full, .photo, ext.isEmpty ? base : "\(base).\(ext)")]
            } else {
                for r in resources where r.type == .photo || r.type == .alternatePhoto {
                    chosen.append((r, r.type, r.originalFilename))
                }
            }
            guard !chosen.isEmpty else { continue }
            var files: [DuplicatePlan.File] = []
            for (n, entry) in chosen.enumerated() {
                let url = directory.appendingPathComponent("\(index)-\(n)-\(entry.filename)")
                try await writeResource(entry.resource, to: url)
                files.append(.init(type: entry.type, url: url, filename: entry.filename))
            }
            plans.append(DuplicatePlan(files: files, creationDate: asset.creationDate, location: asset.location, isFavorite: asset.isFavorite))
        }
        guard !plans.isEmpty else { throw LibraryActionError.notAllowed("These items can't be duplicated.") }

        let created = IDSlot()
        let work = plans
        try await perform { @Sendable in
            for plan in work {
                let request = PHAssetCreationRequest.forAsset()
                for file in plan.files {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.filename
                    options.shouldMoveFile = true
                    request.addResource(with: file.type, fileURL: file.url, options: options)
                }
                request.creationDate = plan.creationDate
                request.location = plan.location
                request.isFavorite = plan.isFavorite
                if let placeholder = request.placeholderForCreatedAsset { created.append(placeholder.localIdentifier) }
            }
        }
        return created.values
    }

    // MARK: Albums

    /// Creates an empty album and returns its identifier.
    public nonisolated static func createAlbum(title: String) async throws -> String {
        let name = try cleanTitle(title)
        let created = IDSlot()
        try await perform { @Sendable in
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            created.append(request.placeholderForCreatedAssetCollection.localIdentifier)
        }
        guard let id = created.values.first else { throw LibraryActionError.notFound }
        return id
    }

    public nonisolated static func renameAlbum(id: String, title: String) async throws {
        let name = try cleanTitle(title)
        let album = try requireAlbum(id)
        guard album.canPerform(.rename) else { throw LibraryActionError.notAllowed("This album can't be renamed.") }
        try await perform { @Sendable in
            guard let album = fetchAlbum(id) else { return }
            PHAssetCollectionChangeRequest(for: album)?.title = name
        }
    }

    /// Deletes the album; its photos stay in the library.
    public nonisolated static func deleteAlbum(id: String) async throws {
        let album = try requireAlbum(id)
        guard album.canPerform(.delete) else { throw LibraryActionError.notAllowed("This album can't be deleted.") }
        try await perform { @Sendable in
            guard let album = fetchAlbum(id) else { return }
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
    }

    public nonisolated static func add(_ ids: [String], toAlbum albumID: String) async throws {
        guard !ids.isEmpty else { return }
        let album = try requireAlbum(albumID)
        guard album.canPerform(.addContent) else { throw LibraryActionError.notAllowed("Photos can't be added to this album.") }
        try requireAssets(ids)
        try await perform { @Sendable in
            guard let album = fetchAlbum(albumID) else { return }
            PHAssetCollectionChangeRequest(for: album)?.addAssets(nsArray(fetchAssets(ids)))
        }
    }

    public nonisolated static func remove(_ ids: [String], fromAlbum albumID: String) async throws {
        guard !ids.isEmpty else { return }
        let album = try requireAlbum(albumID)
        guard album.canPerform(.removeContent) else { throw LibraryActionError.notAllowed("Photos can't be removed from this album.") }
        try requireAssets(ids)
        try await perform { @Sendable in
            guard let album = fetchAlbum(albumID) else { return }
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(nsArray(fetchAssets(ids)))
        }
    }

    /// Adds to the target and removes from the source in one change, so it is one undo step and never
    /// leaves the photos in neither album.
    public nonisolated static func move(_ ids: [String], from sourceAlbumID: String, to targetAlbumID: String) async throws {
        guard !ids.isEmpty, sourceAlbumID != targetAlbumID else { return }
        let source = try requireAlbum(sourceAlbumID)
        let target = try requireAlbum(targetAlbumID)
        guard source.canPerform(.removeContent) else { throw LibraryActionError.notAllowed("Photos can't be removed from this album.") }
        guard target.canPerform(.addContent) else { throw LibraryActionError.notAllowed("Photos can't be added to that album.") }
        try requireAssets(ids)
        try await perform { @Sendable in
            guard let source = fetchAlbum(sourceAlbumID), let target = fetchAlbum(targetAlbumID) else { return }
            let assets = nsArray(fetchAssets(ids))
            PHAssetCollectionChangeRequest(for: target)?.addAssets(assets)
            PHAssetCollectionChangeRequest(for: source)?.removeAssets(assets)
        }
    }

    /// Creates an album and puts the photos in it in one change; returns the album's identifier.
    public nonisolated static func addToNewAlbum(_ ids: [String], title: String) async throws -> String {
        let name = try cleanTitle(title)
        try requireAssets(ids)
        let created = IDSlot()
        try await perform { @Sendable in
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            created.append(request.placeholderForCreatedAssetCollection.localIdentifier)
            request.addAssets(nsArray(fetchAssets(ids)))
        }
        guard let id = created.values.first else { throw LibraryActionError.notFound }
        return id
    }

    // MARK: Reads

    /// The user's regular albums, flattened depth-first in Photos' manual order (folders contribute their
    /// titles to `path`, empty folders vanish). Counts are pictures only.
    public nonisolated static func userAlbums() -> [AlbumEntry] {
        var entries: [AlbumEntry] = []
        collect(PHCollectionList.fetchTopLevelUserCollections(with: nil), path: [], into: &entries)
        return entries
    }

    public nonisolated static func albumCapabilities(id: String) -> AlbumCapabilities? {
        fetchAlbum(id).map(capabilities(of:))
    }

    /// The asset's favorite flag; nil when the asset is gone.
    public nonisolated static func isFavorite(id: String) -> Bool? {
        fetchAssets([id]).firstObject?.isFavorite
    }

    /// Identifiers of the user's albums that contain the asset.
    public nonisolated static func albumIDs(containing assetID: String) -> Set<String> {
        guard let asset = fetchAssets([assetID]).firstObject else { return [] }
        let result = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var ids: Set<String> = []
        for index in 0..<result.count { ids.insert(result.object(at: index).localIdentifier) }
        return ids
    }

    // MARK: Live updates

    /// Identifiers of the changed assets whose pixels changed (an edit, a revert), as opposed to
    /// metadata-only changes (favorite, hidden, caption, album membership). Fill
    /// `LibraryChangeSummary.contentChangedIDs` with this; see `AssetVersions.apply`.
    public nonisolated static func contentChangedIDs(in change: PHChange, details: PHFetchResultChangeDetails<PHAsset>) -> [String] {
        var ids: [String] = []
        for asset in details.changedObjects {
            guard let objectDetails = change.changeDetails(for: asset), !objectDetails.objectWasDeleted else { continue }
            if objectDetails.assetContentChanged { ids.append(asset.localIdentifier) }
        }
        return ids
    }

    // MARK: Internals

    private nonisolated static func cleanTitle(_ title: String) throws -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryActionError.emptyTitle }
        return name
    }

    private nonisolated static func fetchAssets(_ ids: [String]) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
    }

    private nonisolated static func assetList(_ ids: [String]) -> [PHAsset] {
        let fetch = fetchAssets(ids)
        return (0..<fetch.count).map { fetch.object(at: $0) }
    }

    private nonisolated static func fetchAlbum(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private nonisolated static func requireAssets(_ ids: [String]) throws {
        guard fetchAssets(ids).count > 0 else { throw LibraryActionError.notFound }
    }

    private nonisolated static func requireAlbum(_ id: String) throws -> PHAssetCollection {
        guard let album = fetchAlbum(id) else { throw LibraryActionError.notFound }
        return album
    }

    private nonisolated static func nsArray(_ fetch: PHFetchResult<PHAsset>) -> NSArray {
        fetch.objects(at: IndexSet(integersIn: 0..<fetch.count)) as NSArray
    }

    /// Runs a change block. `body` must be `@Sendable` and built in a nonisolated context.
    private nonisolated static func perform(_ body: @escaping @Sendable () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(body)
    }

    private nonisolated static func capabilities(of collection: PHCollection) -> AlbumCapabilities {
        AlbumCapabilities(
            canAdd: collection.canPerform(.addContent), canRemove: collection.canPerform(.removeContent),
            canRename: collection.canPerform(.rename), canDelete: collection.canPerform(.delete))
    }

    /// Estimate of zero is trusted (cheap); otherwise count pictures only, since the estimate includes videos.
    private nonisolated static func imageCount(in album: PHAssetCollection) -> Int {
        if album.estimatedAssetCount == 0 { return 0 }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(in: album, options: options).count
    }

    private nonisolated static func collect(_ result: PHFetchResult<PHCollection>, path: [String], into entries: inout [AlbumEntry]) {
        for index in 0..<result.count {
            let collection = result.object(at: index)
            let title = collection.localizedTitle ?? "Untitled"
            if let folder = collection as? PHCollectionList {
                collect(PHCollection.fetchCollections(in: folder, options: nil), path: path + [title], into: &entries)
            } else if let album = collection as? PHAssetCollection {
                entries.append(AlbumEntry(id: album.localIdentifier, title: title, path: path,
                                          count: imageCount(in: album), capabilities: capabilities(of: album)))
            }
        }
    }

    private nonisolated static func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// What to import for one duplicated asset.
private struct DuplicatePlan: @unchecked Sendable {
    struct File: Sendable {
        var type: PHAssetResourceType
        var url: URL
        var filename: String
    }
    var files: [File]
    var creationDate: Date?
    var location: CLLocation?
    var isFavorite: Bool
}

/// Identifiers produced inside a change block.
private final class IDSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ id: String) { lock.lock(); stored.append(id); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
