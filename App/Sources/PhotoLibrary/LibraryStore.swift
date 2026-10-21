import AppKit
import MiraCore
import Observation
import Photos

/// Bridges `PHPhotoLibraryChangeObserver` (arbitrary queue) to the main actor.
private final class ChangeRelay: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let onChange: @Sendable () -> Void
    nonisolated init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

private final class WeakStore: @unchecked Sendable {
    weak var store: LibraryStore?
    init(_ store: LibraryStore) { self.store = store }
}

/// The Photos library as the browser sees it: authorization, sidebar sources, the current
/// image fetch (indexed lazily, never copied into an array) and thumbnail caching.
@MainActor
@Observable
final class LibraryStore {
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var sections: [SidebarSection] = []
    private(set) var selectedNodeID: String
    /// Folders the user has opened, persisted by folder id.
    private(set) var expanded: Set<String>
    private(set) var fetchResult: PHFetchResult<PHAsset>?
    /// Bumped whenever the library changes, so cells re-read their asset (edited badges, thumbnails).
    private(set) var revision = 0
    var selectedIndex: Int?

    @ObservationIgnored let imageManager = PHCachingImageManager()
    @ObservationIgnored private var relay: ChangeRelay?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var restoredExpansion = false
    @ObservationIgnored private var rawCache: [String: Bool] = [:]
    @ObservationIgnored private var cachedAssets: [PHAsset] = []
    @ObservationIgnored private var cachedRange: Range<Int> = 0..<0

    static let thumbnailPixels: CGFloat = 320
    static var thumbnailSize: CGSize { CGSize(width: thumbnailPixels, height: thumbnailPixels) }

    private static let selectionKey = "mira.sidebar.selection"
    private static let expandedKey = "mira.sidebar.expanded"

    init() {
        selectedNodeID = UserDefaults.standard.string(forKey: Self.selectionKey) ?? "all"
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }
    var count: Int { fetchResult?.count ?? 0 }

    var selectedNode: SidebarNode? { SidebarModel.node(withID: selectedNodeID, in: sections) }
    /// Titles from the root to the selected node ("Trips", "2021", "West Coast").
    var breadcrumb: [String] { SidebarModel.breadcrumb(to: selectedNodeID, in: sections) ?? [] }
    /// Recently Deleted can be looked at but not edited.
    var isReadOnlySelection: Bool { SidebarLoader.isReadOnly(nodeID: selectedNodeID) }

    /// Rows that can be selected, in display order, for the up/down keys.
    var selectableRows: [SidebarNode] {
        sections.flatMap { SidebarModel.visibleRows(in: $0, expanded: expanded).map(\.node) }.filter { !$0.isFolder }
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey)
    }

    func moveSelection(_ delta: Int) {
        let rows = selectableRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedNodeID }
        let next = min(max(0, (current ?? (delta > 0 ? -1 : rows.count)) + delta), rows.count - 1)
        select(rows[next])
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
        let relay = Self.makeRelay(self)
        self.relay = relay
        PHPhotoLibrary.shared().register(relay)
    }

    /// Built in a `nonisolated` context so the `@Sendable` callback carries no main-actor isolation.
    private nonisolated static func makeRelay(_ store: LibraryStore) -> ChangeRelay {
        let weakStore = WeakStore(store)
        return ChangeRelay { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { weakStore.store?.scheduleRefresh() }
            }
        }
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

    /// Refetches the current grid now and rebuilds the sidebar tree off the main actor.
    func reload() {
        guard isAuthorized else { return }
        refetchGrid()
        treeTask?.cancel()
        treeTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { SidebarLoader.load() }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(built)
        }
    }

    private func apply(_ built: [SidebarSection]) {
        sections = built
        if !restoredExpansion {
            restoredExpansion = true
            let ancestors = SidebarModel.ancestorIDs(of: selectedNodeID, in: built) ?? []
            if !ancestors.isEmpty {
                expanded.formUnion(ancestors)
                UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey)
            }
        }
        if SidebarModel.node(withID: selectedNodeID, in: built) == nil, selectedNodeID != "all" {
            selectedNodeID = "all"
            UserDefaults.standard.set("all", forKey: Self.selectionKey)
            selectedIndex = nil
            refetchGrid()
        }
    }

    private func refetchGrid() {
        fetchResult = fetch(forNodeID: selectedNodeID)
        if let i = selectedIndex, i >= count { selectedIndex = nil }
        stopAllCaching()
        revision += 1
    }

    func select(_ node: SidebarNode) {
        guard !node.isFolder else { return }
        selectedNodeID = node.id
        UserDefaults.standard.set(node.id, forKey: Self.selectionKey)
        selectedIndex = nil
        refetchGrid()
    }

    private func fetch(forNodeID id: String) -> PHFetchResult<PHAsset> {
        switch id {
        case "all":
            return PHAsset.fetchAssets(with: SidebarLoader.imageOptions())
        case "fav":
            return PHAsset.fetchAssets(with: SidebarLoader.favouriteOptions())
        case "recent":
            if let c = SidebarLoader.smartCollection(PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue) {
                return PHAsset.fetchAssets(in: c, options: SidebarLoader.imageOptions())
            }
        default:
            if id.hasPrefix("smart:"), let raw = Int(id.dropFirst(6)) {
                if let c = SidebarLoader.smartCollection(raw) {
                    return PHAsset.fetchAssets(in: c, options: SidebarLoader.imageOptions(includeHidden: SidebarLoader.includesHidden(raw: raw)))
                }
            } else if let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                return PHAsset.fetchAssets(in: c, options: SidebarLoader.imageOptions())
            }
        }
        return PHAsset.fetchAssets(with: SidebarLoader.imageOptions())
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
        return PhotoKitBridge.requestImage(manager: imageManager, asset: asset, size: Self.thumbnailSize,
                                           options: options, deliver: handler)
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
            RAWDetection.containsRAW(PhotoKitBridge.resourceTypeIdentifiers(of: box))
        }.value
        rawCache[id] = result
        return result
    }

    func cachedRAW(_ asset: PHAsset) -> Bool? { rawCache[asset.localIdentifier] }
}
