import Foundation
import Observation
import os

/// What makes a grid thumbnail reusable: the asset, the pixel size it was rendered at, the asset's
/// modification date (an edit changes it) and a per-asset version the library bumps when PhotoKit
/// reports the asset as changed. A different key is a different image.
public struct GridThumbnailKey: Hashable, Sendable {
    public var id: String
    public var pixels: Int
    /// `modificationDate.timeIntervalSinceReferenceDate`; nil when the asset reports none.
    public var modified: Double?
    public var version: Int

    public init(id: String, pixels: Int, modificationDate: Date?, version: Int = 0) {
        self.id = id
        self.pixels = pixels
        self.modified = modificationDate?.timeIntervalSinceReferenceDate
        self.version = version
    }

    /// The key for an asset whose metadata-only changes must not refresh its thumbnail: the version
    /// and modification date come from `versions` (which substitutes the pinned date, see
    /// `AssetVersions.apply`). `modificationDate` is the asset's current `PHAsset.modificationDate`.
    public init(id: String, pixels: Int, modificationDate: Date?, versions: AssetVersions) {
        self.init(id: id, pixels: pixels, modificationDate: versions.effectiveModification(for: id, current: modificationDate), version: versions[id])
    }

    var cacheString: NSString {
        "\(id)|\(pixels)|\(modified.map { String($0) } ?? "-")|\(version)" as NSString
    }
}

/// Counts what the grid asks of PhotoKit, so "no thumbnail churn" can be asserted in tests and read
/// in the log (`thumbs requested=N cached=M ...`, subsystem `com.fieldframes.mira`, category `thumbs`).
/// `@unchecked Sendable`: `counts` is only read or written with `lock` held.
public final class ThumbnailMetrics: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        /// Thumbnail image requests actually sent to PhotoKit.
        public var requests = 0
        /// Cell loads answered from the memory cache without a request.
        public var cacheHits = 0
        /// Assets handed to `startCachingImages`.
        public var assetsPreheated = 0
        /// `stopCachingImages(for:)` calls for part of the window.
        public var stopCalls = 0
        /// `stopCachingImagesForAllAssets()` calls.
        public var stopAllCalls = 0
        public init() {}
    }

    public static let shared = ThumbnailMetrics()
    private static let logger = Logger(subsystem: Perf.subsystem, category: "thumbs")

    private let lock = NSLock()
    private var counts = Snapshot()

    public init() {}

    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return counts }

    public func reset() { lock.lock(); counts = Snapshot(); lock.unlock() }

    public func recordRequest() { update { $0.requests += 1 }; Self.logger.debug("thumbs request \(self.summary, privacy: .public)") }
    public func recordCacheHit() { update { $0.cacheHits += 1 } }
    public func recordPreheat(assets: Int) { update { $0.assetsPreheated += assets }; Self.logger.debug("thumbs startCaching +\(assets) \(self.summary, privacy: .public)") }
    public func recordStop() { update { $0.stopCalls += 1 } }
    public func recordStopAll() { update { $0.stopAllCalls += 1 }; Self.logger.notice("thumbs stopAll \(self.summary, privacy: .public)") }

    /// `requested=N cached=M preheated=P stop=S stopAll=A`.
    public var summary: String {
        let s = snapshot
        return "requested=\(s.requests) cached=\(s.cacheHits) preheated=\(s.assetsPreheated) stop=\(s.stopCalls) stopAll=\(s.stopAllCalls)"
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); change(&counts); lock.unlock()
    }
}

/// Per-asset change counters. The library bumps an asset when PhotoKit reports it changed (an edit,
/// a revert, a favorite); cells key their thumbnail on the counter so only that cell refreshes.
///
/// Metadata-only changes (favorite, hidden, album membership) leave the pixels alone, but PhotoKit
/// reports the asset as changed and may move `PHAsset.modificationDate`, so both the counter and the
/// date in `GridThumbnailKey` would invalidate a thumbnail that is still right. To opt in to keeping
/// the key stable:
///
/// 1. Build every key with `GridThumbnailKey(id:pixels:modificationDate:versions:)`, passing the
///    asset's current `modificationDate` and the library's `AssetVersions`.
/// 2. In `photoLibraryDidChange`, fill `LibraryChangeSummary.contentChangedIDs` with
///    `LibraryActions.contentChangedIDs(in:details:)`, and call
///    `versions.apply(summary, previousModification: { oldAssetsByID[$0]?.modificationDate })`
///    BEFORE swapping in the new fetch result, so the closure still sees the old assets' dates.
///    Content changes are bumped (and un-pinned); metadata-only changes are pinned to the date the
///    asset had before the change and are not bumped.
/// 3. With `contentChangedIDs == nil` (unknown) `apply` bumps every changed id, exactly like `bump`.
///
/// Pins live in memory only; after a relaunch keys use the real date again.
public struct AssetVersions: Sendable, Equatable {
    private struct Pin: Sendable, Equatable { var date: Date? }
    private var map: [String: Int] = [:]
    private var pins: [String: Pin] = [:]
    public init() {}
    public subscript(id: String) -> Int { map[id] ?? 0 }
    public mutating func bump(_ ids: some Sequence<String>) { for id in ids { map[id, default: 0] += 1 } }

    /// Pins the modification date a key uses for `id` (only if not already pinned). A nil date pins "none".
    public mutating func pin(_ id: String, _ date: Date?) {
        if pins[id] == nil { pins[id] = Pin(date: date) }
    }

    /// Drops the pin so keys use the asset's real modification date again.
    public mutating func unpin(_ id: String) { pins[id] = nil }

    public func isPinned(_ id: String) -> Bool { pins[id] != nil }

    /// The pinned date when there is a pin, else `current`.
    public func effectiveModification(for id: String, current: Date?) -> Date? {
        if let pin = pins[id] { return pin.date }
        return current
    }

    /// Applies a change: content changes (or every change, when the summary does not know) are
    /// un-pinned and bumped; metadata-only changes are pinned to `previousModification(id)`, the date
    /// from before the change, and not bumped.
    public mutating func apply(_ summary: LibraryChangeSummary, previousModification: (String) -> Date?) {
        for id in summary.metadataOnlyIDs { pin(id, previousModification(id)) }
        for id in summary.contentIDs { unpin(id) }
        bump(summary.contentIDs)
    }
}

/// How a `PHChange` touched one fetch result, reduced to what the grids need (testable without PhotoKit).
public struct LibraryChangeSummary: Sendable, Equatable {
    /// `PHFetchResultChangeDetails.hasIncrementalChanges`.
    public var isIncremental: Bool
    public var removedCount: Int
    public var insertedCount: Int
    public var hasMoves: Bool
    /// Identifiers of assets whose content or metadata changed.
    public var changedIDs: [String]
    /// The subset of `changedIDs` whose pixels changed (`PHObjectChangeDetails.assetContentChanged`);
    /// see `LibraryActions.contentChangedIDs`. nil = unknown, every changed id is treated as a content change.
    public var contentChangedIDs: [String]?

    public init(isIncremental: Bool, removedCount: Int = 0, insertedCount: Int = 0, hasMoves: Bool = false, changedIDs: [String] = [], contentChangedIDs: [String]? = nil) {
        self.contentChangedIDs = contentChangedIDs
        self.isIncremental = isIncremental
        self.removedCount = removedCount
        self.insertedCount = insertedCount
        self.hasMoves = hasMoves
        self.changedIDs = changedIDs
    }

    /// Changed ids whose pixels changed (all of `changedIDs` when unknown).
    public var contentIDs: [String] {
        guard let content = contentChangedIDs else { return changedIDs }
        let set = Set(content)
        return changedIDs.filter(set.contains)
    }

    /// Changed ids known to be metadata-only (empty when unknown).
    public var metadataOnlyIDs: [String] {
        guard let content = contentChangedIDs else { return [] }
        let set = Set(content)
        return changedIDs.filter { !set.contains($0) }
    }

    /// Photos came, went or moved, so grid positions and counts are different.
    public var membershipChanged: Bool { !isIncremental || removedCount > 0 || insertedCount > 0 || hasMoves }
}

/// The single path by which a grid cell gets a thumbnail: memory cache first, PhotoKit on a miss.
/// `Asset` is the PhotoKit asset in the apps and a stand-in in tests; `fetch` sends the real request.
@MainActor
public final class ThumbnailPipeline<Image: AnyObject, Asset> {
    public typealias Deliver = @MainActor (Image?, _ isDegraded: Bool) -> Void
    /// Sends a request and returns its id. May deliver more than once (degraded, then final).
    public typealias Fetch = @MainActor (Asset, GridThumbnailKey, @escaping Deliver) -> Int
    public typealias Cancel = @MainActor (Int) -> Void

    public let metrics: ThumbnailMetrics
    private let fetch: Fetch
    private let cancelRequest: Cancel
    private let cache = NSCache<NSString, Image>()
    private let cost: (Image) -> Int

    public init(
        metrics: ThumbnailMetrics = .shared, byteLimit: Int = 192 * 1_024 * 1_024,
        cost: @escaping (Image) -> Int = { _ in 1 },
        fetch: @escaping Fetch, cancel: @escaping Cancel
    ) {
        self.metrics = metrics
        self.fetch = fetch
        self.cancelRequest = cancel
        self.cost = cost
        cache.totalCostLimit = byteLimit
    }

    public func cached(_ key: GridThumbnailKey) -> Image? { cache.object(forKey: key.cacheString) }

    /// Delivers the cached image at once, or sends a request. Returns the request id, nil on a cache hit.
    /// Only a final (non-degraded) image is remembered.
    @discardableResult
    public func load(_ key: GridThumbnailKey, asset: Asset, deliver: @escaping Deliver) -> Int? {
        if let hit = cached(key) {
            metrics.recordCacheHit()
            deliver(hit, false)
            return nil
        }
        metrics.recordRequest()
        return fetch(asset, key) { [weak self] image, degraded in
            if let image, !degraded, let self {
                self.cache.setObject(image, forKey: key.cacheString, cost: self.cost(image))
            }
            deliver(image, degraded)
        }
    }

    public func cancel(_ requestID: Int) { cancelRequest(requestID) }
    public func removeAll() { cache.removeAllObjects() }
}

/// One grid cell's thumbnail. `update` is cheap to call on every appearance or change: it does
/// nothing while the cell already shows (or is loading) the image for that key, keeps the old image
/// on screen while an edited asset's new one loads, and clears it when the cell is given another asset.
@MainActor @Observable
public final class ThumbnailCellLoader<Image: AnyObject, Asset> {
    public private(set) var image: Image?
    @ObservationIgnored private var key: GridThumbnailKey?
    @ObservationIgnored private var satisfied = false
    @ObservationIgnored private var requestID: Int?
    @ObservationIgnored private var pipeline: ThumbnailPipeline<Image, Asset>?

    public init() {}

    public func update(_ newKey: GridThumbnailKey?, asset: Asset?, pipeline: ThumbnailPipeline<Image, Asset>) {
        guard let newKey, let asset else {
            cancel()
            key = nil
            image = nil
            satisfied = false
            return
        }
        if newKey == key, satisfied || requestID != nil { return }
        cancel()
        if newKey.id != key?.id { image = nil }
        key = newKey
        satisfied = false
        self.pipeline = pipeline
        let id = pipeline.load(newKey, asset: asset) { [weak self] delivered, degraded in
            guard let self, self.key == newKey else { return }
            if let delivered { self.image = delivered }
            if !degraded {
                self.satisfied = delivered != nil
                self.requestID = nil
            }
        }
        if !satisfied { requestID = id }
    }

    /// Cancels an unfinished request (the cell scrolled away). The shown image stays.
    public func cancel() {
        if let requestID { pipeline?.cancel(requestID) }
        requestID = nil
    }
}

/// Carries positions in a fetch across an incremental PhotoKit change (removals refer to the old
/// fetch, insertions to the new one), so a list of positions (the RAW-only view) survives it.
public enum IndexRemap {
    /// `indices` ascending, positions in the old fetch. Removed ones drop out; the rest shift.
    public static func apply(_ indices: [Int], removed: [Int], inserted: [Int]) -> [Int] {
        let removedSorted = removed.sorted()
        let insertedSorted = inserted.sorted()
        var out: [Int] = []
        out.reserveCapacity(indices.count)
        var r = 0
        for old in indices {
            while r < removedSorted.count, removedSorted[r] < old { r += 1 }
            if r < removedSorted.count, removedSorted[r] == old { continue }
            var position = old - r
            for insertion in insertedSorted { if insertion <= position { position += 1 } else { break } }
            out.append(position)
        }
        return out
    }
}
