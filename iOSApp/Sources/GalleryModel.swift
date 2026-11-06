import MiraCore
import MiraUI
import Photos
import SwiftUI
import UIKit
import os

/// PhotoKit and Core Image types are not Sendable; this box carries them across the few hops that need it.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Every closure handed to PhotoKit is built in a `nonisolated` context and marked `@Sendable`
/// (Photos calls back on its own queues; a main-actor-inherited closure would trap in Swift 6).
enum GalleryKit {
    /// How many cover lookups ran (read by the opt-in gallery perf probe).
    nonisolated static let coverLookupCounter = OSAllocatedUnfairLock(initialState: 0)
    nonisolated static var coverLookups: Int { coverLookupCounter.withLock { $0 } }

    /// Runs `work` on its own detached task, but unlike a bare `Task.detached(...).value` the child is
    /// cancelled when the awaiting task is: a detached task does not inherit cancellation, so a RAW scan
    /// batch or a fetch walk would otherwise run to the end after its album was left.
    nonisolated static func detached<T: Sendable>(
        priority: TaskPriority, _ work: @escaping @Sendable () async -> T
    ) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

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

    /// Cover for a sidebar node: the user album's key asset when it has one, else its most recent picture.
    /// Runs off the main actor.
    nonisolated static func coverAsset(nodeID id: String, filter: LibraryFilter = LibraryFilter()) -> Unchecked<PHAsset>? {
        coverLookupCounter.withLock { $0 += 1 }
        let isUserAlbum = !(id == "all" || id == "fav" || id == "recent" || id.hasPrefix("smart:"))
        if isUserAlbum,
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
           let key = PHAsset.fetchKeyAssets(in: collection, options: nil)?.firstObject,
           key.mediaType == .image {
            return Unchecked(value: key)
        }
        let result = SidebarLoader.fetchAssets(nodeID: id, filter: filter, limit: 1)
        guard let first = result.firstObject else { return nil }
        return Unchecked(value: first)
    }

    /// Identifiers of the library's RAW smart album, or nil when this device has none (then the
    /// filter falls back to per-asset resource lookups). Runs off the main actor.
    nonisolated static func rawAlbumIdentifiers(scope: LibraryFilter.Scope = .all) -> Set<String>? {
        guard let album = SidebarLoader.smartCollection(PHAssetCollectionSubtype.smartAlbumRAW.rawValue) else { return nil }
        let options = PHFetchOptions()
        SidebarLoader.apply(scope: scope, to: options)
        let result = PHAsset.fetchAssets(in: album, options: options)
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
        let raw = RAWScan.isRAW(resources: resources)
        let edited = resources.contains { $0.type == .adjustmentData }
        return (raw, edited)
    }

    /// Whether the asset carries adjustment data (the EDITED badge / the Develop queue's tick); runs off the main actor.
    nonisolated static func isEdited(_ asset: Unchecked<PHAsset>) -> Bool {
        PHAssetResource.assetResources(for: asset.value).contains { $0.type == .adjustmentData }
    }
}

/// One node's picture count, observed on its own so only that node's label re-evaluates.
@MainActor @Observable
final class CountBox {
    var value: Int?
}

/// Root gallery state: authorization, the album tree (shared `SidebarLoader` + MiraCore `SidebarModel`),
/// and the change signal that tells open grids to refetch.
@MainActor @Observable
final class GalleryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// The sidebar structure for the current scope. Counts of user albums, shared albums, media types and utilities
    /// are not in it: they arrive in `counts` as the tiles ask for them.
    private(set) var sections: [SidebarSection] = []
    private(set) var loadedSections = false
    /// Library scope (PERSONAL / SHARED / ALL), persisted. Changing it reloads the sections and every cache.
    var scope: LibraryFilter.Scope {
        didSet {
            guard scope != oldValue else { return }
            LibraryScopeStore.save(scope, to: defaults)
            scopeChanged()
        }
    }
    /// Picture counts by node id, filled on demand off the main actor and kept current from library changes.
    /// Not observed itself: views read a node's count through `count(of:)`, which observes only that node's `CountBox`,
    /// so one count arriving re-evaluates one label, not every label.
    @ObservationIgnored private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var countBoxes: [String: CountBox] = [:]
    /// Counts fetched by tiles, waiting for the next flush (one publish per ~frame instead of one per tile).
    @ObservationIgnored private var pendingCounts: [String: Int] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Nodes known to hold no pictures (hidden from the lists).
    private(set) var emptyIDs: Set<String> = []
    /// Bumps when the scope changes: every cover is stale then.
    private(set) var scopeEpoch = 0
    /// Queued Develop photos that are in the current scope (nil: not looked up, or the scope is ALL).
    private(set) var developInScope: Set<String>?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let tracker: LibraryTracker
    @ObservationIgnored private var secondaryTask: Task<Void, Never>?
    var filter: LibraryFilter {
        var f = LibraryFilter()
        f.scope = scope
        return f
    }
    /// Bumps when pictures were added, removed or reordered library-wide (covers are stale then).
    /// Pure content edits do not bump it; they reach the open album as per-asset versions.
    private(set) var revision = 0
    /// Bumps on every library change (selection chrome re-reads flags on it). Covers do not use it: they
    /// follow `coverVersions`, which only the albums that really changed bump.
    private(set) var changeCount = 0
    /// Per-album cover refreshes: an album whose membership changed gets a new cover.
    private(set) var coverVersions: [String: Int] = [:]
    private(set) var openPhase: OpenPhase = .idle
    var isOpening: Bool { if case .opening = openPhase { true } else { false } }
    @ObservationIgnored private var openSerial = 0

    enum OpenPhase {
        case idle
        case opening(detail: String?)
        case failed(asset: PHAsset, message: String)
    }

    @ObservationIgnored private var observing = false
    @ObservationIgnored private var sectionsTask: Task<Void, Never>?
    @ObservationIgnored private var sectionsPending = false
    /// Shared by every cover tile: one caching manager and an in-memory cover cache.
    @ObservationIgnored let covers = CoverStore()
    /// RAW answers shared by every album grid; cleared when the library changes.
    @ObservationIgnored var rawClassification: RAWClassification?
    @ObservationIgnored var rawCandidates: Set<String>?
    @ObservationIgnored let rawChanges = RAWChangeTracker()
    /// Open albums, told about each change so they can apply it in place.
    @ObservationIgnored let openAlbums = NSHashTable<AlbumModel>.weakObjects()

    var hasAccess: Bool { status == .authorized || status == .limited }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = LibraryScopeStore.load(from: defaults)
        scope = saved
        tracker = LibraryTracker(scope: saved)
        super.init()
    }

    /// The picture count of a node when it is known (nil: not loaded yet, or a folder).
    func count(for nodeID: String) -> Int? {
        counts[nodeID] ?? SidebarModel.node(withID: nodeID, in: sections)?.count
    }

    /// The count of a node already in hand (no tree walk).
    func count(of node: SidebarNode) -> Int? { countBox(node.id).value ?? node.count }

    private func countBox(_ id: String) -> CountBox {
        if let box = countBoxes[id] { return box }
        let box = CountBox()
        box.value = counts[id]
        countBoxes[id] = box
        return box
    }

    /// Entries the lists show: nodes known to be empty are left out (Photos' own rule).
    func visible(_ nodes: [SidebarNode]) -> [SidebarNode] {
        // Reads `emptyIDs` (which changes only when a count of zero turns up), never `counts`: the list that calls
        // this must not re-evaluate for every count that arrives.
        nodes.filter { !emptyIDs.contains($0.id) && ($0.count ?? 1) > 0 }
    }

    /// Fetches a node's count off the main actor unless it is known, and keeps it current. Tiles call this from
    /// `.task`, so a tile scrolled away before its turn is cancelled and never fetched.
    func ensureCount(_ nodeID: String) async {
        if counts[nodeID] != nil || pendingCounts[nodeID] != nil { return }
        let tracker = tracker
        let generation = tracker.currentGeneration
        let found = await GalleryKit.detached(priority: .userInitiated) { () -> Int? in
            if Task.isCancelled { return nil }
            return tracker.count(nodeID: nodeID)
        }
        guard let found, !Task.isCancelled, generation == tracker.currentGeneration else { return }
        pendingCounts[nodeID] = found
        scheduleFlush()
    }

    /// Publishes the counts tiles have fetched since the last flush in one mutation, about one frame later.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(24))
            guard let self else { return }
            self.flushTask = nil
            self.flushPending()
        }
    }

    private func flushPending() {
        guard !pendingCounts.isEmpty else { return }
        let batch = pendingCounts
        pendingCounts = [:]
        publish(counts: batch)
    }

    func publish(counts new: [String: Int]) {
        var empty = emptyIDs
        for (id, value) in new {
            pendingCounts[id] = nil
            guard counts[id] != value else { continue }
            counts[id] = value
            countBoxes[id]?.value = value
            if value == 0 { empty.insert(id) } else { empty.remove(id) }
        }
        if empty != emptyIDs { emptyIDs = empty }
    }

    private func scopeChanged() {
        scopeEpoch += 1
        tracker.reset(scope: scope)
        counts = [:]
        pendingCounts = [:]
        for box in countBoxes.values { box.value = nil }
        emptyIDs = []
        developInScope = nil
        covers.removeAll()
        rawClassification = nil
        rawCandidates = nil
        sections = []
        loadedSections = false
        secondaryTask?.cancel()
        guard hasAccess else { return }
        Task {
            await reloadSections()
            for album in openAlbums.allObjects { await album.reload(rawOnly: album.rawOnly, gallery: self) }
        }
    }

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

    /// Builds the section structure from collection lists only (no per-album counts), off the main actor, so the
    /// first screen does not wait for the library to be counted. Media-type and utility counts follow in a
    /// background pass. Requests that arrive while a load is running (a burst of library changes) share it: one
    /// more pass runs after it, so the sections always reflect the last change and loads never finish out of order.
    func reloadSections() async {
        if let running = sectionsTask {
            sectionsPending = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            repeat {
                guard let self else { return }
                self.sectionsPending = false
                let tracker = self.tracker
                let generation = tracker.currentGeneration
                let filter = self.filter
                let loaded = await Task.detached(priority: .userInitiated) {
                    () -> (sections: [SidebarSection], watched: [Unchecked<AnyObject>], counts: [String: Int]) in
                    var counts: [String: Int] = [:]
                    let built = SidebarLoader.structure(filter: filter) { id in
                        let n = tracker.count(nodeID: id) ?? 0
                        counts[id] = n
                        return n
                    }
                    return (built.sections, built.watched, counts)
                }.value
                if generation == tracker.currentGeneration {
                    tracker.watch(structure: loaded.watched, generation: generation)
                    let scoped = SidebarModel.applying(scope: self.scope, to: loaded.sections)
                    // An unchanged tree is not re-published (the album list would re-evaluate for nothing).
                    if scoped != self.sections { self.sections = scoped }
                    self.publish(counts: loaded.counts)
                    self.loadedSections = true
                    self.countSecondaryNodes()
                }
            } while self?.sectionsPending == true
            self?.sectionsTask = nil
        }
        sectionsTask = task
        await task.value
    }

    /// Counts the Media Types and Utilities nodes in the background, right after the first paint (a dozen small
    /// fetches), so rows that turn out empty leave the list before they are reached.
    private func countSecondaryNodes() {
        let ids = sections.filter { $0.id == "media" || $0.id == "utilities" }
            .flatMap(\.nodes).map(\.id).filter { counts[$0] == nil }
        guard !ids.isEmpty else { return }
        secondaryTask?.cancel()
        let tracker = tracker
        let generation = tracker.currentGeneration
        secondaryTask = Task { [weak self] in
            let found = await GalleryKit.detached(priority: .utility) { () -> [String: Int] in
                var out: [String: Int] = [:]
                for id in ids {
                    if Task.isCancelled { break }
                    if let n = tracker.count(nodeID: id) { out[id] = n }
                }
                return out
            }
            guard let self, !Task.isCancelled, generation == tracker.currentGeneration else { return }
            self.publish(counts: found)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let (dropped, membershipChanged) = rawChanges.inspect(changeInstance)
        let boxed = Unchecked(value: changeInstance)
        // Applied here, on Photos' own queue and in delivery order: held results move forward one change at a time.
        let outcome = tracker.process(changeInstance)
        Task.detached(priority: .utility) {
            if let dropped { await RAWScanStore.shared.invalidate(ids: dropped) } else { await RAWScanStore.shared.clearAll() }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.status
                self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                self.changeCount += 1
                if self.hasAccess {
                    if membershipChanged {
                        self.revision += 1
                        self.rawClassification = nil
                        self.rawCandidates = nil
                    }
                    for album in self.openAlbums.allObjects { album.apply(boxed.value, gallery: self) }
                    for id in outcome.changedCounts.keys { self.invalidateCover(nodeID: id) }
                    self.publish(counts: outcome.changedCounts)
                    if outcome.structureChanged || before != self.status { Task { await self.reloadSections() } }
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
        openSerial += 1
        let serial = openSerial
        openPhase = .opening(detail: nil)
        let result = await editor.openAsset(asset) { [weak self] event in
            Task { @MainActor in
                guard let self, self.openSerial == serial, self.isOpening else { return }
                self.openPhase = .opening(detail: EditingInputStatus.text(for: event))
            }
        }
        guard openSerial == serial else { return }
        switch result {
        case .opened, .superseded:
            openPhase = .idle
        case .failed(let error):
            if error is CancellationError {
                openPhase = .idle
            } else if case AssetEditError.photosDidNotDeliver = error {
                openPhase = .failed(asset: asset, message: FFOpenFailureCard.defaultMessage)
            } else {
                openPhase = .failed(asset: asset, message: error.localizedDescription)
            }
        }
    }

    /// Re-opens the asset whose open failed.
    func retry(in editor: EditorViewModel) async {
        guard case .failed(let asset, _) = openPhase else { return }
        await open(asset, in: editor)
    }

    func dismissFailure() {
        if case .failed = openPhase { openPhase = .idle }
    }

    /// An album's membership changed: its cover is stale, other covers are not.
    func invalidateCover(nodeID: String) {
        covers.remove(nodeID: nodeID)
        coverVersions[nodeID, default: 0] += 1
    }

    /// Changes when this node's cover may be a different picture. Only the albums a change touched move
    /// (`coverVersions`), plus the scope; a library change elsewhere leaves every other tile alone.
    func coverToken(for nodeID: String?) -> String {
        "\(scopeEpoch).\(nodeID.flatMap { coverVersions[$0] } ?? 0)"
    }

    func presentLimitedPicker() {
        guard let top = LibraryShare.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
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
    @ObservationIgnored private var cachedCenter = 0
    private static let cachingSlack = 12
    @ObservationIgnored private(set) var thumbSize: CGSize = .zero
    @ObservationIgnored let metrics = ThumbnailMetrics.shared
    /// PhotoKit reported these assets changed (edit, revert, favorite): their cells fetch a new thumbnail.
    private(set) var versions = AssetVersions()
    /// Told after each change with the ids that left this album (nil = not incremental, re-check). Set by the library UI.
    @ObservationIgnored var onMembershipChange: (([String]?) -> Void)?
    /// Memory cache + the one request path for this album's grid thumbnails.
    @ObservationIgnored private(set) lazy var thumbnails = ThumbnailPipeline<UIImage, PHAsset>(
        metrics: metrics,
        cost: { image in max(1, Int(image.size.width * image.size.height * image.scale * image.scale) * 4) },
        fetch: { [weak self] asset, key, deliver in
            // The album is gone with its view; nothing is left to show a thumbnail (0 = no request).
            guard let self else { return 0 }
            let side = CGFloat(key.pixels)
            return Int(GalleryKit.requestThumbnail(
                manager: self.caching, asset: Unchecked(value: asset), size: CGSize(width: side, height: side),
                options: Unchecked(value: self.thumbOptions)
            ) { box, degraded in
                MainActor.assumeIsolated { deliver(box.value, degraded) }
            })
        },
        cancel: { [weak self] id in self?.caching.cancelImageRequest(PHImageRequestID(id)) })

    /// The grid cell's side in pixels (300 until the grid has measured itself).
    var thumbPixels: Int { thumbSize == .zero ? 300 : Int(thumbSize.width) }

    /// The size every request is made at. The caching manager only answers from its cache for the exact
    /// size, content mode and options of the request, so preheating uses this (whole pixels), not the
    /// measured fractional `thumbSize`.
    private var requestSize: CGSize { CGSize(width: thumbPixels, height: thumbPixels) }

    func thumbnailKey(for asset: PHAsset) -> GridThumbnailKey {
        GridThumbnailKey(id: asset.localIdentifier, pixels: thumbPixels,
                         modificationDate: asset.modificationDate, versions: versions)
    }

    init(nodeID: String) { self.nodeID = nodeID }

    /// RAW / EDITED answers per asset, so a cell that scrolls back in does not read the asset's resources
    /// again. A cell shows them from the cache on its first frame. Keyed by the asset's thumbnail version:
    /// an edit bumps it, so the EDITED badge is read again then.
    @ObservationIgnored private var badgeCache: [String: (version: Int, raw: Bool, edited: Bool)] = [:]

    func cachedBadges(id: String, version: Int) -> (raw: Bool, edited: Bool)? {
        guard let hit = badgeCache[id], hit.version == version else { return nil }
        return (hit.raw, hit.edited)
    }

    func storeBadges(_ badges: (raw: Bool, edited: Bool), id: String, version: Int) {
        if badgeCache.count > 20_000 { badgeCache.removeAll() }
        badgeCache[id] = (version, badges.raw, badges.edited)
    }

    func reload(rawOnly: Bool, gallery: GalleryModel) async {
        let id = nodeID
        let filter = gallery.filter
        let box = await Task.detached(priority: .userInitiated) {
            Unchecked(value: SidebarLoader.fetchAssets(nodeID: id, filter: filter))
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
            stopCaching()
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
            let ids = await GalleryKit.detached(priority: .userInitiated) { GalleryKit.identifiers(of: box) }
            guard !Task.isCancelled, let self else { return }
            var classification = gallery.rawClassification
            // Hidden and Recently Deleted pictures are not in the RAW smart album: those two are scanned.
            if GalleryKit.excludedFromRAWAlbum(nodeID: self.nodeID) { classification = RAWClassification(authoritative: false) }
            else if classification == nil {
                let scope = gallery.scope
                let album = await GalleryKit.detached(priority: .userInitiated) { GalleryKit.rawAlbumIdentifiers(scope: scope) }
                classification = album.map { RAWClassification(rawIDs: $0) } ?? RAWClassification(authoritative: false)
                if album != nil { gallery.rawClassification = classification }
            }
            guard var classification, !Task.isCancelled else { return }
            if classification.authoritative {
                self.finishBatch(classification.matchingIndices(in: ids), done: true)
                return
            }
            if gallery.rawCandidates == nil {
                gallery.rawCandidates = await GalleryKit.detached(priority: .userInitiated) { RAWScan.candidateIDs() }
            }
            let candidates = gallery.rawCandidates
            var matches: [Int] = []
            for range in RAWScanBatching.ranges(count: ids.count, size: 200) {
                if Task.isCancelled { return }
                let todo = Array(range)
                let flags = await GalleryKit.detached(priority: .utility) {
                    await RAWScan.flags(in: box, indices: todo, candidates: candidates, store: RAWScanStore.shared)
                }
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

    private func publish(_ indices: [Int]) {
        displayIndices = indices
        count = indices.count
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
            hasMoves: details.hasMoves, changedIDs: details.changedObjects.map(\.localIdentifier),
            contentChangedIDs: LibraryActions.contentChangedIDs(in: change, details: details))
        let after = details.fetchResultAfterChanges
        let previous = Dictionary(details.changedObjects.map { object -> (String, Date?) in
            let at = current.index(of: object)
            return (object.localIdentifier, at == NSNotFound ? object.modificationDate : current.object(at: at).modificationDate)
        }, uniquingKeysWith: { first, _ in first })
        // Metadata-only changes (favorite, hidden, album membership) keep the old key; edits bump it.
        versions.apply(summary, previousModification: { previous[$0] ?? nil })
        result = after
        onMembershipChange?(summary.isIncremental ? removed.isEmpty ? [] : details.removedObjects.map(\.localIdentifier) : nil)
        guard summary.membershipChanged else { return }
        gallery.invalidateCover(nodeID: nodeID)
        if !removed.isEmpty {
            caching.stopCachingImages(for: details.removedObjects, targetSize: requestSize, contentMode: .aspectFill, options: thumbOptions)
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

    func setThumbSize(_ size: CGSize) {
        guard size != thumbSize else { return }
        let before = thumbPixels
        thumbSize = size
        // A window preheated at another size is never stopped (stop calls use the current size): drop it.
        if thumbPixels != before, !cachedRange.isEmpty { stopCaching() }
    }

    /// Keeps a window of ±36 around the visible index warm in the caching manager. Cells appear in bursts that
    /// are not in scroll order (the lazy grid builds a few rows ahead and behind), and every appearance used
    /// to move the window: assets just dropped were started again a moment later. The window now moves once
    /// the index is a dozen cells off its centre, so the part that matters (±24 cells) is always covered.
    func updateCaching(around index: Int) {
        guard result != nil, thumbSize != .zero else { return }
        if !cachedRange.isEmpty, abs(index - cachedCenter) < Self.cachingSlack,
           cachedRange.upperBound == min(count, cachedCenter + 36) { return }
        let window = max(0, index - 36)..<min(count, index + 36)
        guard window != cachedRange else { return }
        cachedCenter = index
        let old = Set(cachedRange), new = Set(window)
        let add = new.subtracting(old).sorted(), drop = old.subtracting(new).sorted()
        if !add.isEmpty {
            let assets = add.compactMap { asset(at: $0) }
            caching.startCachingImages(for: assets, targetSize: requestSize, contentMode: .aspectFill, options: thumbOptions)
            metrics.recordPreheat(assets: assets.count)
        }
        if !drop.isEmpty {
            caching.stopCachingImages(for: drop.compactMap { asset(at: $0) },
                                      targetSize: requestSize, contentMode: .aspectFill, options: thumbOptions)
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

extension DevelopStore {
    /// Of these identifiers, the ones Photos still has, whatever their source (user library, shared albums, synced)
    /// and hidden or not: the library scope never decides whether a queued photo exists. Runs off the main actor.
    nonisolated static func existingIdentifiers(among ids: [String]) -> Set<String> {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allSourcesOptions())
        var found = Set<String>()
        result.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }
}

extension DevelopStore {
    /// Every source, hidden included: for lookups that ask "does this photo exist".
    nonisolated static func allSourcesOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeHiddenAssets = true
        o.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return o
    }

    /// Of these identifiers, the ones the scope shows (by each picture's own source). Runs off the main actor.
    nonisolated static func identifiers(among ids: [String], inScope scope: LibraryFilter.Scope) -> Set<String> {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: allSourcesOptions())
        let wanted = SidebarLoader.sourceTypes(for: scope)
        var found = Set<String>()
        result.enumerateObjects { asset, _, _ in
            if wanted == nil || !asset.sourceType.isDisjoint(with: wanted!) { found.insert(asset.localIdentifier) }
        }
        return found
    }
}

extension GalleryModel {
    /// The queued entries the current scope shows (all of them under ALL, or until the lookup has answered).
    func developEntries(_ queue: DevelopQueue) -> [DevelopQueue.Entry] {
        DevelopScopeFilter.visible(queue.entries, scope: scope, inScope: developInScope)
    }

    /// Looks up which queued photos are in the scope, off the main actor. Not run under ALL.
    func refreshDevelopScope(ids: [String]) async {
        guard scope != .all, !ids.isEmpty else { developInScope = nil; return }
        let scope = self.scope
        let found = await GalleryKit.detached(priority: .utility) { DevelopStore.identifiers(among: ids, inScope: scope) }
        guard !Task.isCancelled, scope == self.scope else { return }
        developInScope = found
    }
}
