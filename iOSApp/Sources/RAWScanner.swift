import Foundation
import MiraCore
import Photos

/// PhotoKit and RAW on iOS (checked against the iPhoneOS 27 SDK headers):
/// - `PHAssetCollectionSubtypeSmartAlbumRAW` (217) is declared `ios(15)`, but a device only returns a collection
///   for it when the library has RAW assets in it; `fetchAssetCollections(...).firstObject` can be nil, then we scan.
/// - `PHAssetMediaSubtype` has no RAW bit (panorama, HDR, screenshot, live, depth, animation, spatial; video kinds).
///   Its only use here is to skip screenshots and animations, which are never RAW, via a fetch predicate.
/// - A RAW capture shows as a `.photo` resource with a RAW UTType, or as a `.alternatePhoto` resource beside a
///   JPEG/HEIC `.photo` (RAW+JPEG pair). `PHAssetResource.assetResources(for:)` is the per-asset check.
enum RAWScan {
    /// Screenshot | animation.
    static let skippedSubtypes: UInt = PHAssetMediaSubtype.photoScreenshot.rawValue | PHAssetMediaSubtype.photoAnimation.rawValue

    nonisolated static func candidateOptions() -> PHFetchOptions {
        let o = SidebarLoader.imageOptions()
        o.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0",
                                  PHAssetMediaType.image.rawValue, skippedSubtypes)
        return o
    }

    /// Identifiers of every image that could be RAW (not a screenshot or animation). Runs off the main actor.
    nonisolated static func candidateIDs() -> Set<String> {
        let r = PHAsset.fetchAssets(with: candidateOptions())
        var ids = Set<String>()
        ids.reserveCapacity(r.count)
        for i in 0..<r.count { ids.insert(r.object(at: i).localIdentifier) }
        return ids
    }

    nonisolated static func isRAW(_ asset: PHAsset) -> Bool {
        RAWResourceClassifier.isRAW(PHAssetResource.assetResources(for: asset).map(ResourceFields.init))
    }

    private struct ResourceFields: RAWResourceDescribing {
        let rawRole: RAWResourceRole
        let rawTypeIdentifier: String
        nonisolated init(_ r: PHAssetResource) {
            rawTypeIdentifier = r.uniformTypeIdentifier
            switch r.type {
            case .photo: rawRole = .photo
            case .alternatePhoto: rawRole = .alternatePhoto
            default: rawRole = .other
            }
        }
    }

    /// RAW flag for each requested index: cache first, non-candidates are false, the rest are checked on a few
    /// parallel lanes and written back to the cache. Runs off the main actor.
    nonisolated static func flags(in result: Unchecked<PHFetchResult<PHAsset>>, indices: [Int],
                                  candidates: Set<String>?, store: RAWScanStore) async -> [(Int, Bool)] {
        var items: [(index: Int, id: String, modified: Date?, asset: Unchecked<PHAsset>)] = []
        items.reserveCapacity(indices.count)
        for i in indices {
            let a = result.value.object(at: i)
            items.append((i, a.localIdentifier, a.modificationDate, Unchecked(value: a)))
        }
        let cached = await store.lookup(items.map { ($0.id, $0.modified) })
        var out: [(Int, Bool)] = []
        var todo: [(index: Int, id: String, modified: Date?, asset: Unchecked<PHAsset>)] = []
        for (n, item) in items.enumerated() {
            if let hit = cached[n] { out.append((item.index, hit)) }
            else if let candidates, !candidates.contains(item.id) { out.append((item.index, false)) }
            else { todo.append(item) }
        }
        guard !todo.isEmpty else { return out }
        let fresh = await withTaskGroup(of: [(Int, String, Date?, Bool)].self) { group in
            for slice in RAWScanBatching.slices(todo, lanes: 3) {
                group.addTask {
                    var part: [(Int, String, Date?, Bool)] = []
                    for item in slice {
                        if Task.isCancelled { break }
                        part.append((item.index, item.id, item.modified, RAWScan.isRAW(item.asset.value)))
                    }
                    return part
                }
            }
            var all: [(Int, String, Date?, Bool)] = []
            for await part in group { all += part }
            return all
        }
        await store.record(fresh.map { ($0.1, $0.2, $0.3) })
        out += fresh.map { ($0.0, $0.3) }
        return out
    }
}

/// Persistent per-asset RAW answers (Caches/RAWScan.json), loaded once and written off the main actor, debounced.
actor RAWScanStore {
    static let shared = RAWScanStore()
    private var cache: RAWResultCache
    private var saveTask: Task<Void, Never>?
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("RAWScan.json")
        cache = RAWResultCache.load(from: url)
    }

    func lookup(_ keys: [(String, Date?)]) -> [Bool?] {
        keys.map { cache.lookup(id: $0.0, modificationDate: $0.1) }
    }

    func record(_ results: [(String, Date?, Bool)]) {
        for r in results { cache.record(id: r.0, modificationDate: r.1, isRAW: r.2) }
        scheduleSave()
    }

    func invalidate(ids: [String]) {
        cache.invalidate(ids: ids)
        scheduleSave()
    }

    func clearAll() {
        cache.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = cache, target = url
            await Task.detached(priority: .utility) { try? snapshot.write(to: target) }.value
        }
    }
}

/// Keeps one lazily-evaluated fetch of the library's images so `PHChange` can say which assets changed.
final class RAWChangeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PHFetchResult<PHAsset>?

    nonisolated func prime() {
        lock.lock(); defer { lock.unlock() }
        if result == nil { result = PHAsset.fetchAssets(with: SidebarLoader.imageOptions()) }
    }

    /// Identifiers of changed or removed images, or nil when the change cannot be itemised (clear everything).
    nonisolated func invalidatedIDs(for change: PHChange) -> [String]? {
        inspect(change).invalidated
    }

    /// What a change did to the library's pictures: which ids to forget (nil: everything) and whether
    /// pictures were added, removed or reordered (covers and RAW answers are only stale then; a pure
    /// content edit leaves them valid).
    nonisolated func inspect(_ change: PHChange) -> (invalidated: [String]?, membershipChanged: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let current = result else { return ([], true) }
        guard let details = change.changeDetails(for: current) else { return ([], false) }
        result = details.fetchResultAfterChanges
        guard details.hasIncrementalChanges else { return (nil, true) }
        let before = details.fetchResultBeforeChanges
        var ids = details.changedObjects.map(\.localIdentifier)
        for i in details.removedIndexes ?? [] where i < before.count { ids.append(before.object(at: i).localIdentifier) }
        let membership = !(details.removedIndexes?.isEmpty ?? true) || !(details.insertedIndexes?.isEmpty ?? true) || details.hasMoves
        return (ids, membership)
    }
}
