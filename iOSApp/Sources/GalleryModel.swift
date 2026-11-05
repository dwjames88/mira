import MiraCore
import Photos
import SwiftUI
import UIKit

/// PhotoKit and Core Image types are not Sendable; this box carries them across the few hops that need it.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Every closure handed to PhotoKit is built in a `nonisolated` context and marked `@Sendable`
/// (Photos calls back on its own queues; a main-actor-inherited closure would trap in Swift 6).
enum GalleryKit {
    nonisolated static func requestThumbnail(
        manager: PHImageManager, asset: Unchecked<PHAsset>, size: CGSize, options: Unchecked<PHImageRequestOptions>,
        deliver: @escaping @Sendable (Unchecked<UIImage?>, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID {
        manager.requestImage(for: asset.value, targetSize: size, contentMode: .aspectFill, options: options.value) {
            @Sendable image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let box = Unchecked(value: image)
            DispatchQueue.main.async { deliver(box, degraded) }
        }
    }

    nonisolated static func requestFullData(asset: Unchecked<PHAsset>) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let boxed = Unchecked(value: options)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset.value, options: boxed.value) {
                @Sendable data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Cover for a sidebar node: the user album's key asset when it has one, else its most recent picture.
    /// Runs off the main actor.
    nonisolated static func coverAsset(nodeID id: String) -> Unchecked<PHAsset>? {
        let isUserAlbum = !(id == "all" || id == "fav" || id == "recent" || id.hasPrefix("smart:"))
        if isUserAlbum,
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
           let key = PHAsset.fetchKeyAssets(in: collection, options: nil)?.firstObject,
           key.mediaType == .image {
            return Unchecked(value: key)
        }
        let result = SidebarLoader.fetchAssets(nodeID: id)
        guard let first = result.firstObject else { return nil }
        return Unchecked(value: first)
    }

    /// Identifiers of the library's RAW smart album, or nil when this device has none (then the
    /// filter falls back to per-asset resource lookups). Runs off the main actor.
    nonisolated static func rawAlbumIdentifiers() -> Set<String>? {
        guard let album = SidebarLoader.smartCollection(PHAssetCollectionSubtype.smartAlbumRAW.rawValue) else { return nil }
        let result = PHAsset.fetchAssets(in: album, options: nil)
        var ids = Set<String>()
        ids.reserveCapacity(result.count)
        for i in 0..<result.count { ids.insert(result.object(at: i).localIdentifier) }
        return ids
    }

    /// True for the Hidden and Recently Deleted albums, whose pictures the RAW smart album leaves out.
    nonisolated static func excludedFromRAWAlbum(nodeID id: String) -> Bool {
        guard id.hasPrefix("smart:"), let raw = Int(id.dropFirst(6)) else { return false }
        return SidebarLoader.includesHidden(raw: raw)
    }

    /// Local identifiers of a fetch, in order. Runs off the main actor.
    nonisolated static func identifiers(of result: Unchecked<PHFetchResult<PHAsset>>) -> [String] {
        let r = result.value
        var ids: [String] = []
        ids.reserveCapacity(r.count)
        for i in 0..<r.count {
            if i % 2048 == 0, Task.isCancelled { return [] }
            ids.append(r.object(at: i).localIdentifier)
        }
        return ids
    }

    /// (isRAW, isEdited) from the asset's resources; runs off the main actor.
    nonisolated static func badges(of asset: Unchecked<PHAsset>) -> (raw: Bool, edited: Bool) {
        let resources = PHAssetResource.assetResources(for: asset.value)
        // Same rule as the RAW filter (any camera-RAW type, not just DNG), so badge and filter agree.
        let raw = RAWScan.isRAW(asset.value)
        let edited = resources.contains { $0.type == .adjustmentData }
        return (raw, edited)
    }
}

/// Root gallery state: authorization, the album tree (shared `SidebarLoader` + MiraCore `SidebarModel`),
/// and the change signal that tells open grids to refetch.
@MainActor @Observable
final class GalleryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var sections: [SidebarSection] = []
    private(set) var loadedSections = false
    /// Bumps when pictures were added, removed or reordered library-wide (covers are stale then).
    /// Pure content edits do not bump it; they reach the open album as per-asset versions.
    private(set) var revision = 0
    /// Bumps on every library change. Album membership can change without the library's picture list
    /// changing (a picture added to an album), so covers re-check their asset on each change.
    private(set) var changeCount = 0
    /// Per-album cover refreshes: an album whose membership changed gets a new cover.
    private(set) var coverVersions: [String: Int] = [:]
    private(set) var isOpening = false

    @ObservationIgnored private var observing = false
    /// Shared by every cover tile: one caching manager and an in-memory cover cache.
    @ObservationIgnored let covers = CoverStore()
    /// RAW answers shared by every album grid; cleared when the library changes.
    @ObservationIgnored var rawClassification: RAWClassification?
    @ObservationIgnored var rawCandidates: Set<String>?
    @ObservationIgnored let rawChanges = RAWChangeTracker()
    /// Open albums, told about each change so they can apply it in place.
    @ObservationIgnored let openAlbums = NSHashTable<AlbumModel>.weakObjects()

    var hasAccess: Bool { status == .authorized || status == .limited }

    /// Picture count of the whole library ("all" node), once sections are loaded.
    var libraryCount: Int? { SidebarModel.node(withID: "all", in: sections)?.count }

    func start() async {
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if hasAccess {
            Task.detached(priority: .utility) { [tracker = rawChanges] in tracker.prime() }
            await reloadSections()
        }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    /// `SidebarLoader` is `nonisolated`; run it off the main actor and hop back with Sendable values.
    func reloadSections() async {
        let loaded = await Task.detached(priority: .userInitiated) { SidebarLoader.load() }.value
        sections = loaded
        loadedSections = true
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let (dropped, membershipChanged) = rawChanges.inspect(changeInstance)
        let boxed = Unchecked(value: changeInstance)
        Task.detached(priority: .utility) {
            if let dropped { await RAWScanStore.shared.invalidate(ids: dropped) } else { await RAWScanStore.shared.clearAll() }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                self.changeCount += 1
                if self.hasAccess {
                    if membershipChanged {
                        self.revision += 1
                        self.covers.removeAll()
                        self.rawClassification = nil
                        self.rawCandidates = nil
                    }
                    for album in self.openAlbums.allObjects { album.apply(boxed.value, gallery: self) }
                    Task { await self.reloadSections() }
                } else {
                    self.sections = []
                }
            }
        }
    }

    /// Opens the asset non-destructively: the editor loads the ORIGINAL pixels and restores any
    /// Mira recipe stored in the asset's adjustment data.
    func open(_ asset: PHAsset, in editor: EditorViewModel) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        await editor.openAsset(asset)
    }

    /// An album's membership changed: its cover is stale, other covers are not.
    func invalidateCover(nodeID: String) {
        covers.remove(nodeID: nodeID)
        coverVersions[nodeID, default: 0] += 1
    }

    func coverToken(for nodeID: String?) -> String {
        "\(revision).\(changeCount).\(nodeID.flatMap { coverVersions[$0] } ?? 0)"
    }

    func presentLimitedPicker() {
        guard let top = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// One album's pictures: the fetch result for a sidebar node plus the thumbnail caching window.
@MainActor @Observable
final class AlbumModel {
    let nodeID: String
    private(set) var result: PHFetchResult<PHAsset>?
    /// Number of cells shown: the whole fetch, or the RAW matches while the RAW filter is on.
    private(set) var count = 0
    private(set) var loaded = false
    /// The ALL / RAW choice. Changing it goes through `setRawOnly`.
    private(set) var rawOnly = false
    /// "scanned / total" while the RAW filter is still checking assets one by one.
    private(set) var scanProgress: (done: Int, total: Int)?
    /// RAW assets found so far in this album (updates while the background scan runs); nil before it starts.
    private(set) var rawCount: Int?
    @ObservationIgnored private var rawMatches: [Int] = []
    private(set) var scanFinished = false
    /// True until the RAW scan of this album has covered every asset.
    var scanning: Bool { !scanFinished }
    @ObservationIgnored private var displayIndices: [Int]?
    @ObservationIgnored private var rawTask: Task<Void, Never>?
    @ObservationIgnored private weak var gallery: GalleryModel?

    @ObservationIgnored let caching = PHCachingImageManager()
    @ObservationIgnored let thumbOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()
    @ObservationIgnored private var cachedRange: Range<Int> = 0..<0
    @ObservationIgnored private(set) var thumbSize: CGSize = .zero
    @ObservationIgnored let metrics = ThumbnailMetrics.shared
    /// PhotoKit reported these assets changed (edit, revert, favorite): their cells fetch a new thumbnail.
    private(set) var versions = AssetVersions()
    /// Memory cache + the one request path for this album's grid thumbnails.
    @ObservationIgnored private(set) lazy var thumbnails = ThumbnailPipeline<UIImage, PHAsset>(
        metrics: metrics,
        cost: { image in max(1, Int(image.size.width * image.size.height * image.scale * image.scale) * 4) },
        fetch: { [unowned self] asset, key, deliver in
            let side = CGFloat(key.pixels)
            return Int(GalleryKit.requestThumbnail(
                manager: self.caching, asset: Unchecked(value: asset), size: CGSize(width: side, height: side),
                options: Unchecked(value: self.thumbOptions)
            ) { box, degraded in
                MainActor.assumeIsolated { deliver(box.value, degraded) }
            })
        },
        cancel: { [unowned self] id in self.caching.cancelImageRequest(PHImageRequestID(id)) })

    /// The grid cell's side in pixels (300 until the grid has measured itself).
    var thumbPixels: Int { thumbSize == .zero ? 300 : Int(thumbSize.width) }

    func thumbnailKey(for asset: PHAsset) -> GridThumbnailKey {
        GridThumbnailKey(id: asset.localIdentifier, pixels: thumbPixels,
                         modificationDate: asset.modificationDate, version: versions[asset.localIdentifier])
    }

    init(nodeID: String) { self.nodeID = nodeID }

    func reload(rawOnly: Bool, gallery: GalleryModel) async {
        let id = nodeID
        let box = await Task.detached(priority: .userInitiated) {
            Unchecked(value: SidebarLoader.fetchAssets(nodeID: id))
        }.value
        self.gallery = gallery
        gallery.openAlbums.add(self)
        result = box.value
        displayIndices = nil
        count = box.value.count
        loaded = true
        stopCaching()
        startScan(gallery: gallery)
        setRawOnly(rawOnly)
    }

    /// Turns the RAW filter on or off. The scan runs in the background either way (it feeds the RAW count);
    /// this only chooses what the grid shows. Matches already found show at once.
    func setRawOnly(_ on: Bool) {
        rawOnly = on
        guard result != nil else { return }
        if on { publish(rawMatches) } else {
            displayIndices = nil
            count = result?.count ?? 0
            resetCaching()
        }
    }

    /// RAW smart album when the device has one (authoritative, instant); otherwise newest-first batches of 200,
    /// each answered from the persistent cache or a few parallel resource checks off the main actor.
    private func startScan(gallery: GalleryModel) {
        rawTask?.cancel()
        rawMatches = []
        scanFinished = false
        rawCount = nil
        scanProgress = nil
        guard let result else { return }
        let box = Unchecked(value: result)
        rawTask = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { GalleryKit.identifiers(of: box) }.value
            guard !Task.isCancelled, let self else { return }
            var classification = gallery.rawClassification
            // Hidden and Recently Deleted pictures are not in the RAW smart album: those two are scanned.
            if GalleryKit.excludedFromRAWAlbum(nodeID: self.nodeID) { classification = RAWClassification(authoritative: false) }
            else if classification == nil {
                let album = await Task.detached(priority: .userInitiated) { GalleryKit.rawAlbumIdentifiers() }.value
                classification = album.map { RAWClassification(rawIDs: $0) } ?? RAWClassification(authoritative: false)
                if album != nil { gallery.rawClassification = classification }
            }
            guard var classification, !Task.isCancelled else { return }
            if classification.authoritative {
                self.finishBatch(classification.matchingIndices(in: ids), done: true)
                return
            }
            if gallery.rawCandidates == nil {
                gallery.rawCandidates = await Task.detached(priority: .userInitiated) { RAWScan.candidateIDs() }.value
            }
            let candidates = gallery.rawCandidates
            var matches: [Int] = []
            for range in RAWScanBatching.ranges(count: ids.count, size: 200) {
                if Task.isCancelled { return }
                let todo = Array(range)
                let flags = await Task.detached(priority: .utility) {
                    await RAWScan.flags(in: box, indices: todo, candidates: candidates, store: RAWScanStore.shared)
                }.value
                for (i, raw) in flags { classification.record(id: ids[i], isRAW: raw) }
                if Task.isCancelled { return }
                matches += classification.matchingIndices(in: ids, range: range)
                let last = range.upperBound >= ids.count
                self.scanProgress = last ? nil : (range.upperBound, ids.count)
                self.finishBatch(matches, done: last)
            }
            if ids.isEmpty { self.finishBatch([], done: true) }
        }
    }

    private func finishBatch(_ matches: [Int], done: Bool) {
        rawMatches = matches
        rawCount = matches.count
        scanFinished = done
        if done { scanProgress = nil }
        if rawOnly { publish(matches) }
    }

    private func publish(_ indices: [Int], replacing: Bool = true) {
        displayIndices = indices
        count = indices.count
        resetCaching()
    }

    private func resetCaching() {
        stopCaching()
    }

    /// Applies a library change to this album in place. Edits only bump the changed assets' versions
    /// (their cells refetch, nothing else does, and the RAW scan is not repeated). Added, removed or
    /// reordered pictures update the fetch, the shown positions and the RAW scan.
    func apply(_ change: PHChange, gallery: GalleryModel) {
        guard let current = result, let details = change.changeDetails(for: current) else { return }
        let removed = Array(details.removedIndexes ?? [])
        let inserted = Array(details.insertedIndexes ?? [])
        let summary = LibraryChangeSummary(
            isIncremental: details.hasIncrementalChanges, removedCount: removed.count, insertedCount: inserted.count,
            hasMoves: details.hasMoves, changedIDs: details.changedObjects.map(\.localIdentifier))
        let after = details.fetchResultAfterChanges
        result = after
        versions.bump(summary.changedIDs)
        guard summary.membershipChanged else { return }
        gallery.invalidateCover(nodeID: nodeID)
        if !removed.isEmpty {
            caching.stopCachingImages(for: details.removedObjects, targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
            metrics.recordStop()
        }
        cachedRange = 0..<0
        if let shown = displayIndices {
            // RAW-only view: carry the positions across, the rescan below adds or removes the rest.
            displayIndices = summary.isIncremental && !summary.hasMoves
                ? IndexRemap.apply(shown, removed: removed, inserted: inserted) : []
            count = displayIndices?.count ?? 0
        } else {
            count = after.count
        }
        startScan(gallery: gallery)
    }

    func cancelWork() { rawTask?.cancel() }

    func stopCaching() {
        caching.stopCachingImagesForAllAssets()
        metrics.recordStopAll()
        cachedRange = 0..<0
    }

    func asset(at index: Int) -> PHAsset? {
        guard let result, index >= 0, index < count else { return nil }
        let source = displayIndices.map { $0[index] } ?? index
        return source < result.count ? result.object(at: source) : nil
    }

    func setThumbSize(_ size: CGSize) { thumbSize = size }

    /// Keeps a window of ±36 around the visible index warm in the caching manager.
    func updateCaching(around index: Int) {
        guard result != nil, thumbSize != .zero else { return }
        let window = max(0, index - 36)..<min(count, index + 36)
        guard window != cachedRange else { return }
        let old = Set(cachedRange), new = Set(window)
        let add = new.subtracting(old).sorted(), drop = old.subtracting(new).sorted()
        if !add.isEmpty {
            let assets = add.compactMap { asset(at: $0) }
            caching.startCachingImages(for: assets, targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
            metrics.recordPreheat(assets: assets.count)
        }
        if !drop.isEmpty {
            caching.stopCachingImages(for: drop.compactMap { asset(at: $0) },
                                      targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
            metrics.recordStop()
        }
        cachedRange = window
    }
}


/// Cover thumbnails for the album browser: one `PHCachingImageManager` and an `NSCache` keyed by node id + size.
@MainActor
final class CoverStore {
    let manager = PHCachingImageManager()
    let options: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    func key(_ nodeID: String, _ size: CGSize) -> String { "\(nodeID)@\(Int(size.width))x\(Int(size.height))" }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    private var keysByNode: [String: Set<String>] = [:]
    /// Which asset each cached cover shows, so a later lookup can tell the cover went stale.
    private var assetIDs: [String: String] = [:]
    func assetID(for key: String) -> String? { assetIDs[key] }
    func store(_ image: UIImage, for key: String, nodeID: String, assetID: String) {
        cache.setObject(image, forKey: key as NSString)
        assetIDs[key] = assetID
        keysByNode[nodeID, default: []].insert(key)
    }
    func remove(nodeID: String) {
        for key in keysByNode.removeValue(forKey: nodeID) ?? [] {
            cache.removeObject(forKey: key as NSString)
            assetIDs[key] = nil
        }
    }
    func removeAll() { cache.removeAllObjects(); keysByNode = [:]; assetIDs = [:] }
}
