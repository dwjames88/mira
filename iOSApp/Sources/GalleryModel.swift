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
        deliver: @escaping @Sendable (Unchecked<UIImage?>) -> Void
    ) -> PHImageRequestID {
        manager.requestImage(for: asset.value, targetSize: size, contentMode: .aspectFill, options: options.value) {
            @Sendable image, _ in
            let box = Unchecked(value: image)
            DispatchQueue.main.async { deliver(box) }
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

    /// Whether the asset at each index has a RAW resource; stops early when cancelled.
    nonisolated static func rawFlags(in result: Unchecked<PHFetchResult<PHAsset>>, indices: [Int]) -> [(Int, Bool)] {
        var out: [(Int, Bool)] = []
        out.reserveCapacity(indices.count)
        for i in indices {
            if Task.isCancelled { break }
            let types = PHAssetResource.assetResources(for: result.value.object(at: i))
                .filter { $0.type == .photo || $0.type == .alternatePhoto }
                .map(\.uniformTypeIdentifier)
            out.append((i, RAWDetection.containsRAW(types)))
        }
        return out
    }

    /// (isRAW, isEdited) from the asset's resources; runs off the main actor.
    nonisolated static func badges(of asset: Unchecked<PHAsset>) -> (raw: Bool, edited: Bool) {
        let resources = PHAssetResource.assetResources(for: asset.value)
        let rawTypes: Set<String> = ["public.camera-raw-image", "com.adobe.raw-image"]
        let raw = resources.contains {
            ($0.type == .photo || $0.type == .alternatePhoto) && rawTypes.contains($0.uniformTypeIdentifier)
        }
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
    /// Bumps whenever the library changes; grids refetch on it.
    private(set) var revision = 0
    private(set) var isOpening = false

    @ObservationIgnored private var observing = false
    /// Shared by every cover tile: one caching manager and an in-memory cover cache.
    @ObservationIgnored let covers = CoverStore()
    /// RAW answers shared by every album grid; cleared when the library changes.
    @ObservationIgnored var rawClassification: RAWClassification?
    @ObservationIgnored var rawFlags: [String: Bool] = [:]

    var hasAccess: Bool { status == .authorized || status == .limited }

    /// Picture count of the whole library ("all" node), once sections are loaded.
    var libraryCount: Int? { SidebarModel.node(withID: "all", in: sections)?.count }

    func start() async {
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if hasAccess { await reloadSections() }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    /// `SidebarLoader` is `nonisolated`; run it off the main actor and hop back with Sendable values.
    func reloadSections() async {
        let loaded = await Task.detached(priority: .userInitiated) { SidebarLoader.load() }.value
        sections = loaded
        loadedSections = true
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if self.hasAccess {
                    self.revision += 1
                    self.covers.removeAll()
                    self.rawClassification = nil
                    self.rawFlags = [:]
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

    init(nodeID: String) { self.nodeID = nodeID }

    func reload(rawOnly: Bool, gallery: GalleryModel) async {
        let id = nodeID
        let box = await Task.detached(priority: .userInitiated) {
            Unchecked(value: SidebarLoader.fetchAssets(nodeID: id))
        }.value
        self.gallery = gallery
        result = box.value
        displayIndices = nil
        count = box.value.count
        loaded = true
        caching.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
        await setRawOnly(rawOnly)
    }

    /// Turns the RAW filter on or off. The RAW smart album answers at once when the device has one;
    /// otherwise assets are checked newest first in chunks, and the grid fills as matches arrive.
    func setRawOnly(_ on: Bool) async {
        rawTask?.cancel()
        rawOnly = on
        scanProgress = nil
        guard let result, let gallery else { return }
        guard on else {
            displayIndices = nil
            count = result.count
            resetCaching()
            return
        }
        displayIndices = []
        count = 0
        resetCaching()
        let box = Unchecked(value: result)
        let task = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { GalleryKit.identifiers(of: box) }.value
            guard !Task.isCancelled, let self else { return }
            var classification = gallery.rawClassification
            if classification == nil {
                let album = await Task.detached(priority: .userInitiated) { GalleryKit.rawAlbumIdentifiers() }.value
                classification = album.map { RAWClassification(rawIDs: $0) }
                    ?? RAWClassification(known: gallery.rawFlags, authoritative: false)
                if album != nil { gallery.rawClassification = classification }
            }
            guard var classification, !Task.isCancelled else { return }
            if classification.authoritative {
                self.publish(classification.matchingIndices(in: ids), replacing: true)
                return
            }
            var matches: [Int] = []
            let chunk = 200
            var start = 0
            while start < ids.count, !Task.isCancelled {
                let range = start..<min(ids.count, start + chunk)
                let todo = classification.unresolved(in: ids, range: range)
                if !todo.isEmpty {
                    let flags = await Task.detached(priority: .utility) { GalleryKit.rawFlags(in: box, indices: todo) }.value
                    for (i, raw) in flags {
                        classification.record(id: ids[i], isRAW: raw)
                        gallery.rawFlags[ids[i]] = raw
                    }
                }
                if Task.isCancelled { return }
                matches += classification.matchingIndices(in: ids, range: range)
                start = range.upperBound
                self.scanProgress = start < ids.count ? (start, ids.count) : nil
                self.publish(matches, replacing: true)
            }
        }
        rawTask = task
        await task.value
    }

    private func publish(_ indices: [Int], replacing: Bool = true) {
        displayIndices = indices
        count = indices.count
        resetCaching()
    }

    private func resetCaching() {
        caching.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
    }

    func cancelWork() { rawTask?.cancel() }

    func stopCaching() {
        caching.stopCachingImagesForAllAssets()
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
            caching.startCachingImages(for: add.compactMap { asset(at: $0) }, targetSize: thumbSize,
                                       contentMode: .aspectFill, options: thumbOptions)
        }
        if !drop.isEmpty {
            caching.stopCachingImages(for: drop.compactMap { asset(at: $0) },
                                      targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
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
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
    func removeAll() { cache.removeAllObjects() }
}
