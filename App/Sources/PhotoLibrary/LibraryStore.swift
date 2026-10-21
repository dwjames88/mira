import AppKit
import EmulsionCore
import Observation
import Photos

/// One entry in the library sidebar.
struct LibrarySource: Identifiable, Hashable {
    enum Kind: Hashable {
        case allPhotos
        case favourites
        case collection(String) // PHAssetCollection.localIdentifier
    }
    let id: String
    let title: String
    let kind: Kind
    var count: Int
}

/// Bridges `PHPhotoLibraryChangeObserver` (arbitrary queue) to the main actor.
private final class ChangeRelay: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

/// The Photos library as the browser sees it: authorization, sidebar sources, the current
/// image fetch (indexed lazily, never copied into an array) and thumbnail caching.
@MainActor
@Observable
final class LibraryStore {
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var librarySources: [LibrarySource] = []
    private(set) var albumSources: [LibrarySource] = []
    private(set) var smartSources: [LibrarySource] = []
    var selectedSourceID = "all"
    private(set) var fetchResult: PHFetchResult<PHAsset>?
    /// Bumped whenever the library changes, so cells re-read their asset (edited badges, thumbnails).
    private(set) var revision = 0
    var selectedIndex: Int?

    @ObservationIgnored let imageManager = PHCachingImageManager()
    @ObservationIgnored private var relay: ChangeRelay?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var rawCache: [String: Bool] = [:]
    @ObservationIgnored private var cachedAssets: [PHAsset] = []
    @ObservationIgnored private var cachedRange: Range<Int> = 0..<0

    static let thumbnailPixels: CGFloat = 320
    static var thumbnailSize: CGSize { CGSize(width: thumbnailPixels, height: thumbnailPixels) }

    init() {
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }
    var count: Int { fetchResult?.count ?? 0 }

    var selectedSource: LibrarySource? {
        (librarySources + albumSources + smartSources).first { $0.id == selectedSourceID }
    }

    // MARK: Authorization

    /// Asks for read/write access if not decided yet, then loads the library.
    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        authorization = status
        if isAuthorized {
            registerObserver()
            reload()
        }
    }

    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != authorization else { return }
        authorization = status
        if isAuthorized { registerObserver(); reload() }
    }

    private func registerObserver() {
        guard relay == nil else { return }
        let relay = ChangeRelay { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        self.relay = relay
        PHPhotoLibrary.shared().register(relay)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.reload()
        }
    }

    // MARK: Fetching

    private static func imageOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// Rebuilds the sidebar and the current grid. Keeps the selection.
    func reload() {
        guard isAuthorized else { return }
        let imageOptions = Self.imageOptions()

        var library = [LibrarySource(id: "all", title: "All Photos", kind: .allPhotos,
                                     count: PHAsset.fetchAssets(with: imageOptions).count)]
        let favOptions = Self.imageOptions()
        favOptions.predicate = NSPredicate(format: "mediaType == %d AND favorite == YES", PHAssetMediaType.image.rawValue)
        library.append(LibrarySource(id: "fav", title: "Favourites", kind: .favourites,
                                     count: PHAsset.fetchAssets(with: favOptions).count))
        librarySources = library

        var albums: [LibrarySource] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                let n = PHAsset.fetchAssets(in: collection, options: imageOptions).count
                albums.append(LibrarySource(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled",
                                            kind: .collection(collection.localIdentifier), count: n))
            }
        albumSources = albums

        let smartTypes: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumRAW, "RAW"), (.smartAlbumRecentlyAdded, "Recently Added"),
            (.smartAlbumScreenshots, "Screenshots"), (.smartAlbumSelfPortraits, "Selfies"),
            (.smartAlbumDepthEffect, "Portrait"), (.smartAlbumPanoramas, "Panoramas"),
            (.smartAlbumLivePhotos, "Live Photos"),
        ]
        var smart: [LibrarySource] = []
        for (subtype, fallbackTitle) in smartTypes {
            guard let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            else { continue }
            let n = PHAsset.fetchAssets(in: collection, options: imageOptions).count
            guard n > 0 else { continue }
            smart.append(LibrarySource(id: collection.localIdentifier, title: collection.localizedTitle ?? fallbackTitle,
                                       kind: .collection(collection.localIdentifier), count: n))
        }
        smartSources = smart

        if selectedSource == nil { selectedSourceID = "all" }
        fetchResult = fetch(for: selectedSource?.kind ?? .allPhotos)
        if let i = selectedIndex, i >= count { selectedIndex = nil }
        stopAllCaching()
        revision += 1
    }

    func select(_ source: LibrarySource) {
        selectedSourceID = source.id
        selectedIndex = nil
        fetchResult = fetch(for: source.kind)
        stopAllCaching()
        revision += 1
    }

    private func fetch(for kind: LibrarySource.Kind) -> PHFetchResult<PHAsset> {
        switch kind {
        case .allPhotos:
            return PHAsset.fetchAssets(with: Self.imageOptions())
        case .favourites:
            let options = Self.imageOptions()
            options.predicate = NSPredicate(format: "mediaType == %d AND favorite == YES", PHAssetMediaType.image.rawValue)
            return PHAsset.fetchAssets(with: options)
        case .collection(let id):
            if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                return PHAsset.fetchAssets(in: collection, options: Self.imageOptions())
            }
            return PHAsset.fetchAssets(with: Self.imageOptions())
        }
    }

    func asset(at index: Int) -> PHAsset? {
        guard let fetchResult, index >= 0, index < fetchResult.count else { return nil }
        return fetchResult.object(at: index)
    }

    // MARK: Thumbnails

    /// Requests a thumbnail; the handler may run twice (degraded, then final). Returns the request id.
    func requestThumbnail(for asset: PHAsset, handler: @escaping @MainActor (NSImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return imageManager.requestImage(for: asset, targetSize: Self.thumbnailSize,
                                         contentMode: .aspectFill, options: options) { image, _ in
            let box = Unchecked(value: image)
            MainActor.assumeIsolated { handler(box.value) }
        }
    }

    func cancelThumbnail(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }

    /// Keeps a window of assets around `index` warm in the caching manager.
    func prefetch(around index: Int) {
        guard let fetchResult, fetchResult.count > 0 else { return }
        if index >= cachedRange.lowerBound + 12, index < cachedRange.upperBound - 24, !cachedAssets.isEmpty { return }
        let lower = max(0, index - 30)
        let upper = min(fetchResult.count, index + 90)
        guard lower < upper else { return }
        let range = lower..<upper
        let assets = fetchResult.objects(at: IndexSet(integersIn: range))
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        if !cachedAssets.isEmpty {
            let keep = Set(assets.map(\.localIdentifier))
            let stale = cachedAssets.filter { !keep.contains($0.localIdentifier) }
            if !stale.isEmpty {
                imageManager.stopCachingImages(for: stale, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: options)
            }
        }
        imageManager.startCachingImages(for: assets, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: options)
        cachedAssets = assets
        cachedRange = range
    }

    private func stopAllCaching() {
        imageManager.stopCachingImagesForAllAssets()
        cachedAssets = []
        cachedRange = 0..<0
    }

    // MARK: RAW

    /// True when the asset has a RAW resource. Computed once per asset, off the main actor.
    func isRAW(_ asset: PHAsset) async -> Bool {
        let id = asset.localIdentifier
        if let cached = rawCache[id] { return cached }
        let box = Unchecked(value: asset)
        let result = await Task.detached(priority: .utility) {
            let ids = PHAssetResource.assetResources(for: box.value)
                .filter { $0.type == .photo || $0.type == .alternatePhoto }
                .map(\.uniformTypeIdentifier)
            return RAWDetection.containsRAW(ids)
        }.value
        rawCache[id] = result
        return result
    }

    func cachedRAW(_ asset: PHAsset) -> Bool? { rawCache[asset.localIdentifier] }
}
