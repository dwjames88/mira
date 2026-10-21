import Foundation
import MiraCore
import Photos

/// The identity of every asset in a fetch, copied out of PhotoKit once so the filter can run over plain arrays.
struct CollectionScan: Sendable {
    var ids: [String]
    var dates: [Date?]
    /// `hasAdjustments` per asset; nil until a filter asks for it (it is read per asset, so it costs a pass).
    var edited: [Bool]?
}

/// What a filter pass produced.
struct FilterOutcome: Sendable {
    var scan: CollectionScan
    /// Indices into the fetch result that match, or nil when the fetch itself already is the answer.
    var indices: [Int]?
    var facets: FilterFacets
    var rawIDs: Set<String>?
}

/// PhotoKit reads and the filter pass. Everything is `nonisolated`, uses no closures (fetch results are
/// walked by index) and is meant to run off the main actor.
enum FilterEngine {
    /// Copies ids, creation dates and (when `withEdited`) the adjusted flag out of the fetch. Nil when cancelled.
    nonisolated static func scan(_ fetch: Unchecked<PHFetchResult<PHAsset>>, withEdited: Bool) -> CollectionScan? {
        let result = fetch.value
        let n = result.count
        var ids: [String] = []
        var dates: [Date?] = []
        var edited: [Bool] = []
        ids.reserveCapacity(n); dates.reserveCapacity(n)
        if withEdited { edited.reserveCapacity(n) }
        for i in 0..<n {
            if i % 2048 == 0, Task.isCancelled { return nil }
            let asset = result.object(at: i)
            ids.append(asset.localIdentifier)
            dates.append(asset.creationDate)
            if withEdited { edited.append(asset.hasAdjustments) }
        }
        return CollectionScan(ids: ids, dates: dates, edited: withEdited ? edited : nil)
    }

    /// Local identifiers of the library's RAW photos (the RAW smart album).
    nonisolated static func rawIdentifiers() -> Set<String> {
        guard let album = SidebarLoader.smartCollection(PHAssetCollectionSubtype.smartAlbumRAW.rawValue) else { return [] }
        let result = PHAsset.fetchAssets(in: album, options: nil)
        var ids = Set<String>()
        ids.reserveCapacity(result.count)
        for i in 0..<result.count { ids.insert(result.object(at: i).localIdentifier) }
        return ids
    }

    /// One filter pass. Reuses `previousScan` / `previousRAW` when they cover what the filter needs.
    nonisolated static func compute(
        fetch: Unchecked<PHFetchResult<PHAsset>>, filter: LibraryFilter, store: MetadataStore,
        previousScan: CollectionScan?, previousRAW: Set<String>?
    ) -> FilterOutcome? {
        var scan = previousScan
        if scan == nil || (filter.editedOnly && scan?.edited == nil) {
            scan = Self.scan(fetch, withEdited: filter.editedOnly)
        }
        guard let scan, !Task.isCancelled else { return nil }
        var raw = previousRAW
        if filter.rawOnly, raw == nil { raw = rawIdentifiers() }
        let metas = store.metadata(forIDs: scan.ids)
        let facets = LibraryFilter.facets(of: metas)
        guard filter.needsAssetPass else {
            return FilterOutcome(scan: scan, indices: nil, facets: facets, rawIDs: raw)
        }
        let indices = filter.matchingIndices(
            count: scan.ids.count,
            facts: { i in
                AssetFacts(id: scan.ids[i], creationDate: scan.dates[i], isRAW: raw?.contains(scan.ids[i]) ?? false,
                           isEdited: scan.edited?[i] ?? false,
                           // Favorites are applied by the fetch predicate, so every fetched asset already is one.
                           isFavorite: filter.favoritesOnly)
            },
            meta: { metas[$0] })
        return FilterOutcome(scan: scan, indices: indices, facets: facets, rawIDs: raw)
    }
}
