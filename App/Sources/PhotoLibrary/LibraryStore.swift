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

private final class LookupFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
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
    /// Sections the user has folded away, persisted by section id.
    private(set) var collapsedSections: Set<String>
    private(set) var fetchResult: PHFetchResult<PHAsset>?
    /// The grid's criteria. Change it with `updateFilter`.
    private(set) var filter = LibraryFilter()
    /// Indices into `fetchResult` that pass the filter; nil when the whole fetch is shown.
    private(set) var displayIndices: [Int]?
    /// A filter pass is running, so the grid may not match the criteria yet.
    private(set) var filterPending = false
    /// Camera and lens counts for the current collection, from the metadata index.
    private(set) var facets = FilterFacets()
    private(set) var indexProgress = IndexProgress()
    /// Set by the filter popover; while it is open the facets are kept fresh as the index grows.
    private(set) var filterPanelOpen = false

    func setFilterPanelOpen(_ open: Bool) {
        guard open != filterPanelOpen else { return }
        filterPanelOpen = open
        if open { schedulePass(delay: .milliseconds(50), replace: true) }
    }
    /// Bumped whenever the library changes, so cells re-read their asset (edited badges, thumbnails).
    private(set) var revision = 0
    var selectedIndex: Int?

    @ObservationIgnored let imageManager = PHCachingImageManager()
    @ObservationIgnored private var relay: ChangeRelay?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var restoredExpansion = false
    @ObservationIgnored let metadataStore = MetadataStore(fileURL: MetadataStore.defaultFileURL())
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var passGeneration = 0
    @ObservationIgnored private var scan: CollectionScan?
    @ObservationIgnored private var rawIDs: Set<String>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexRestartTask: Task<Void, Never>?
    @ObservationIgnored private var indexFlag = IndexCancelFlag()
    @ObservationIgnored private var indexRun = 0
    @ObservationIgnored private var metadataLoaded = false
    @ObservationIgnored private var lastCovered = false
    @ObservationIgnored private var rawCache: [String: Bool] = [:]
    @ObservationIgnored private var cachedAssets: [PHAsset] = []
    @ObservationIgnored private var cachedRange: Range<Int> = 0..<0

    /// Thumbnail size in pixels: the grid cell in points times the backing scale, rounded up to 64 so
    /// a window resize does not invalidate the caching manager's images for every pixel of movement.
    private(set) var thumbnailPixels: CGFloat = 320
    var thumbnailSize: CGSize { CGSize(width: thumbnailPixels, height: thumbnailPixels) }

    /// One options object for requests and for the caching manager, so cached images are hit.
    @ObservationIgnored private let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // iCloud-optimised libraries keep many originals and thumbnails off the Mac; opportunistic
        // delivery still shows any local low-quality image first, then the downloaded one.
        options.isNetworkAccessAllowed = true
        return options
    }()
    /// The last thumbnail each cell showed, so opening a photo can show it at once.
    @ObservationIgnored private var shownThumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var shownOrder: [String] = []
    @ObservationIgnored private let rawQueue = DispatchQueue(label: "com.fieldframes.mira.raw-lookup", qos: .utility)

    private static let selectionKey = "mira.sidebar.selection"
    private static let expandedKey = "mira.sidebar.expanded"
    private static let collapsedSectionsKey = "mira.sidebar.collapsedSections"

    init() {
        selectedNodeID = UserDefaults.standard.string(forKey: Self.selectionKey) ?? "all"
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
        collapsedSections = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsKey) ?? [])
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }
    /// Photos shown in the grid: the filtered list when a filter is active, else the whole fetch.
    var count: Int { displayIndices?.count ?? fetchResult?.count ?? 0 }
    /// Photos in the collection before the filter's per-asset criteria.
    var collectionCount: Int { fetchResult?.count ?? 0 }
    /// The index has seen every photo in the current collection (the filter's metadata criteria are complete).
    var indexCoversCollection: Bool { indexProgress.finished || indexProgress.scope == .library }

    var selectedNode: SidebarNode? { SidebarModel.node(withID: selectedNodeID, in: sections) }
    /// Titles from the root to the selected node ("Trips", "2021", "West Coast").
    var breadcrumb: [String] { SidebarModel.breadcrumb(to: selectedNodeID, in: sections) ?? [] }
    /// Recently Deleted can be looked at but not edited.
    var isReadOnlySelection: Bool { SidebarLoader.isReadOnly(nodeID: selectedNodeID) }

    /// Rows that can be selected, in display order, for the up/down keys.
    var selectableRows: [SidebarNode] {
        SidebarModel.selectableNodes(in: sections, expanded: expanded, collapsedSections: collapsedSections)
    }

    func isSectionCollapsed(_ id: String) -> Bool { collapsedSections.contains(id) }

    func toggleSection(_ id: String) {
        if collapsedSections.contains(id) { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
        UserDefaults.standard.set(Array(collapsedSections).sorted(), forKey: Self.collapsedSectionsKey)
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
            await loadMetadataStore()
            reload()
        }
    }

    private func loadMetadataStore() async {
        guard !metadataLoaded else { return }
        metadataLoaded = true
        let store = metadataStore
        await Task.detached(priority: .utility) { _ = store.load() }.value
    }

    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != authorization else { return }
        authorization = status
        if isAuthorized {
            registerObserver()
            Task { [weak self] in
                await self?.loadMetadataStore()
                self?.reload()
            }
        }
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
        refetchGrid(keepVisible: true)
        restartIndexing(delay: .milliseconds(500))
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
            restartIndexing(delay: .zero)
        }
    }

    /// Refetches the current collection. With a per-asset filter active the new fetch is filtered off the
    /// main actor first; `keepVisible` keeps the old grid on screen until that finishes (library changes),
    /// otherwise the grid empties while it runs (a different collection).
    private func refetchGrid(keepVisible: Bool = false) {
        let fresh = SidebarLoader.fetchAssets(nodeID: selectedNodeID, filter: filter)
        scan = nil
        if filter.needsAssetPass {
            if !keepVisible {
                fetchResult = fresh
                displayIndices = []
                stopAllCaching()
                revision += 1
            }
            runPass(newFetch: fresh)
        } else {
            fetchResult = fresh
            displayIndices = nil
            filterPending = false
            if let i = selectedIndex, i >= count { selectedIndex = nil }
            stopAllCaching()
            revision += 1
            // Facets for the popover and the metadata criteria's bookkeeping.
            if filterPanelOpen { runPass(newFetch: nil) }
        }
    }

    func select(_ node: SidebarNode) {
        guard !node.isFolder else { return }
        selectedNodeID = node.id
        UserDefaults.standard.set(node.id, forKey: Self.selectionKey)
        selectedIndex = nil
        refetchGrid()
        restartIndexing(delay: .milliseconds(400))
    }

    /// The photo at a grid position, mapped through the filter.
    func asset(at index: Int) -> PHAsset? {
        guard let fetchResult, index >= 0, index < count else { return nil }
        let source = displayIndices?[index] ?? index
        guard source < fetchResult.count else { return nil }
        return fetchResult.object(at: source)
    }

    // MARK: Filter

    /// Applies a change to the criteria. PhotoKit-expressible ones (favorites, scope) refetch; the rest
    /// re-run the off-main pass over the collection.
    func updateFilter(_ change: (inout LibraryFilter) -> Void) {
        let old = filter
        var new = old
        change(&new)
        guard new != old else { return }
        filter = new
        selectedIndex = nil
        if old.fetchCriteria != new.fetchCriteria {
            refetchGrid()
        } else if new.needsAssetPass {
            filterPending = true
            schedulePass(delay: .milliseconds(150), replace: true)
        } else {
            passTask?.cancel()
            passGeneration += 1
            displayIndices = nil
            filterPending = false
            revision += 1
        }
    }

    func resetFilter() {
        updateFilter { $0 = LibraryFilter() }
    }

    private func schedulePass(delay: Duration, replace: Bool) {
        if !replace, passTask != nil { return }
        passTask?.cancel()
        passGeneration += 1
        let generation = passGeneration
        passTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == self.passGeneration else { return }
            self.runPass(newFetch: nil)
        }
    }

    /// Runs the filter off the main actor and publishes the result if nothing newer started meanwhile.
    /// With `newFetch` the grid swaps to that fetch together with the filtered list.
    private func runPass(newFetch: PHFetchResult<PHAsset>?) {
        guard let target = newFetch ?? fetchResult else { return }
        passTask?.cancel()
        passGeneration += 1
        let generation = passGeneration
        let criteria = filter
        let box = Unchecked(value: target)
        let store = metadataStore
        let previousScan = newFetch == nil ? scan : nil
        let previousRAW = rawIDs
        filterPending = criteria.needsAssetPass
        passTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                FilterEngine.compute(fetch: box, filter: criteria, store: store, previousScan: previousScan, previousRAW: previousRAW)
            }
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, generation == self.passGeneration, let outcome else { return }
            self.passTask = nil
            self.scan = outcome.scan
            self.rawIDs = outcome.rawIDs
            self.facets = outcome.facets
            self.filterPending = false
            if let newFetch {
                self.fetchResult = newFetch
                self.stopAllCaching()
            }
            if self.displayIndices != outcome.indices || newFetch != nil {
                self.displayIndices = outcome.indices
                if let i = self.selectedIndex, i >= self.count { self.selectedIndex = nil }
                self.revision += 1
            }
        }
    }

    // MARK: Metadata index

    /// (Re)starts the background index on the current collection, then the rest of the library.
    private func restartIndexing(delay: Duration) {
        indexRestartTask?.cancel()
        indexRestartTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.isAuthorized else { return }
            self.startIndexing()
        }
    }

    private func startIndexing() {
        indexFlag.cancel()
        indexTask?.cancel()
        let flag = IndexCancelFlag()
        indexFlag = flag
        indexRun += 1
        let run = indexRun
        let nodeID = selectedNodeID
        let store = metadataStore
        let report = Self.makeProgressReporter(self, run: run)
        indexTask = Task.detached(priority: .utility) {
            // Unfiltered fetches: the index describes the collection whatever the filter currently hides.
            let collection = Unchecked(value: SidebarLoader.fetchAssets(nodeID: nodeID))
            let library = nodeID == "all" ? nil : Unchecked(value: PHAsset.fetchAssets(with: SidebarLoader.imageOptions()))
            await MetadataIndexer.run(collection: collection, library: library, store: store, flag: flag, report: report)
        }
    }

    /// Built in a `nonisolated` context so the `@Sendable` callback carries no main-actor isolation.
    private nonisolated static func makeProgressReporter(_ store: LibraryStore, run: Int) -> @Sendable (IndexProgress) -> Void {
        let weakStore = WeakStore(store)
        return { @Sendable progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { weakStore.store?.indexDidProgress(progress, run: run) }
            }
        }
    }

    private func indexDidProgress(_ progress: IndexProgress, run: Int) {
        guard run == indexRun else { return }
        indexProgress = progress
        let covered = indexCoversCollection
        let becameCovered = covered && !lastCovered
        lastCovered = covered
        guard filter.needsMetadata || filterPanelOpen else { return }
        // While indexing, refresh the list and the facets about once a second; do it at once when the
        // collection becomes fully covered or the run ends.
        if becameCovered || progress.finished {
            schedulePass(delay: .milliseconds(100), replace: true)
        } else {
            schedulePass(delay: .seconds(1), replace: false)
        }
    }

    // MARK: Thumbnails

    /// Sets the thumbnail size from the cell's side in points and the window's backing scale.
    func setCellSize(points: CGFloat, scale: CGFloat) {
        let pixels = max(64, (points * scale / 64).rounded(.up) * 64)
        guard pixels != thumbnailPixels else { return }
        stopAllCaching()
        thumbnailPixels = pixels
    }

    /// Requests a thumbnail; the handler may run twice (degraded, then final). Returns the request id.
    func requestThumbnail(for asset: PHAsset, handler: @escaping @MainActor (NSImage?) -> Void) -> PHImageRequestID {
        let id = asset.localIdentifier
        return PhotoKitBridge.requestImage(
            manager: imageManager, asset: asset, size: thumbnailSize, options: thumbnailOptions, signpost: true
        ) { [weak self] image in
            if let image { self?.remember(image, id: id) }
            handler(image)
        }
    }

    /// A larger image for the editor to show while the editing input loads.
    func requestStandIn(for asset: PHAsset, handler: @escaping @MainActor (NSImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return PhotoKitBridge.requestImage(
            manager: imageManager, asset: asset, size: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit, options: options, deliver: handler)
    }

    func cancelThumbnail(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }

    func cachedThumbnail(for asset: PHAsset) -> NSImage? { shownThumbnails[asset.localIdentifier] }

    private func remember(_ image: NSImage, id: String) {
        if shownThumbnails.updateValue(image, forKey: id) == nil {
            shownOrder.append(id)
            if shownOrder.count > 400 { shownThumbnails[shownOrder.removeFirst()] = nil }
        }
    }

    /// Keeps a window of assets around `index` warm in the caching manager: the visible cells plus
    /// a little ahead and behind, nothing more.
    func prefetch(around index: Int) {
        guard count > 0 else { return }
        if index >= cachedRange.lowerBound + 12, index < cachedRange.upperBound - 24, !cachedAssets.isEmpty { return }
        let lower = max(0, index - 30)
        let upper = min(count, index + 90)
        guard lower < upper else { return }
        let range = lower..<upper
        let assets = range.compactMap { asset(at: $0) }
        if !cachedAssets.isEmpty {
            let keep = Set(assets.map(\.localIdentifier))
            let stale = cachedAssets.filter { !keep.contains($0.localIdentifier) }
            if !stale.isEmpty {
                imageManager.stopCachingImages(for: stale, targetSize: thumbnailSize, contentMode: .aspectFill, options: thumbnailOptions)
            }
        }
        imageManager.startCachingImages(for: assets, targetSize: thumbnailSize, contentMode: .aspectFill, options: thumbnailOptions)
        cachedAssets = assets
        cachedRange = range
    }

    private func stopAllCaching() {
        imageManager.stopCachingImagesForAllAssets()
        cachedAssets = []
        cachedRange = 0..<0
    }

    // MARK: RAW

    /// True when the asset has a RAW resource. Computed once per asset on one serial background
    /// queue; a lookup whose cell scrolled away before its turn is skipped.
    func isRAW(_ asset: PHAsset) async -> Bool {
        let id = asset.localIdentifier
        if let cached = rawCache[id] { return cached }
        let box = Unchecked(value: asset)
        let flag = LookupFlag()
        let result: Bool? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                rawQueue.async {
                    if flag.isCancelled { continuation.resume(returning: nil); return }
                    let raw = RAWDetection.containsRAW(PhotoKitBridge.resourceTypeIdentifiers(of: box))
                    continuation.resume(returning: raw)
                }
            }
        } onCancel: { flag.cancel() }
        if let result { rawCache[id] = result }
        return result ?? false
    }

    func cachedRAW(_ asset: PHAsset) -> Bool? { rawCache[asset.localIdentifier] }
}
