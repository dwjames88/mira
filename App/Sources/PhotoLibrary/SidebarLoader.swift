import Foundation
import MiraCore
import Photos

/// A user collection copied out of PhotoKit into plain values, so the tree can be built and
/// handed between threads without holding on to `PHCollection` objects.
struct CollectionSnapshot: CollectionNodeSource {
    let title: String
    let identifier: String
    let isFolder: Bool
    let children: [any CollectionNodeSource]
    let assetCount: Int
    /// False when the count was left out (the iPhone fetches album counts on demand).
    var assetCountKnown = true
}

/// Builds the sidebar sections from PhotoKit. Everything here is `nonisolated` and uses no closures
/// (fetch results are walked by index), so it runs on any thread; callers hop to the main actor
/// with the finished, Sendable value types.
enum SidebarLoader {
    /// `PHAssetCollectionSubtype` raw value of Recently Deleted, which the SDK enum does not declare.
    nonisolated static let recentlyDeletedRaw = 1_000_000_201
    nonisolated static let hiddenRaw = 205

    nonisolated static func smartID(_ raw: Int) -> String { "smart:\(raw)" }

    /// Pictures only, newest first. Hidden and deleted assets are included only for their own albums.
    /// The filter's PhotoKit-expressible criteria (favorites, source scope) are folded into the fetch.
    nonisolated static func imageOptions(includeHidden: Bool = false, filter: LibraryFilter = LibraryFilter()) -> PHFetchOptions {
        let options = PHFetchOptions()
        var format = "mediaType == %d"
        if filter.favoritesOnly { format += " AND favorite == YES" }
        options.predicate = NSPredicate(format: format, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = includeHidden
        apply(scope: filter.scope, to: options)
        return options
    }

    /// `PHAssetSourceType` for the scope. The Mac leaves ALL at PhotoKit's default (as it always did);
    /// the iPhone spells out the user library plus shared albums.
    nonisolated static func sourceTypes(for scope: LibraryFilter.Scope) -> PHAssetSourceType? {
        #if os(iOS)
        let ios = true
        #else
        let ios = false
        #endif
        guard let kinds = LibraryFilter.sourceKinds(for: scope, iOS: ios) else { return nil }
        var types: PHAssetSourceType = []
        for kind in kinds {
            switch kind {
            case .userLibrary: types.insert(.typeUserLibrary)
            case .cloudShared: types.insert(.typeCloudShared)
            }
        }
        return types
    }

    nonisolated static func apply(scope: LibraryFilter.Scope, to options: PHFetchOptions) {
        if let types = sourceTypes(for: scope) { options.includeAssetSourceTypes = types }
    }

    nonisolated static func favoriteOptions() -> PHFetchOptions {
        var filter = LibraryFilter()
        filter.favoritesOnly = true
        return imageOptions(filter: filter)
    }

    nonisolated static func smartCollection(_ raw: Int) -> PHAssetCollection? {
        guard let subtype = PHAssetCollectionSubtype(rawValue: raw) else { return nil }
        return PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
    }

    /// Whether the album with this smart id must be opened read-only.
    nonisolated static func isReadOnly(nodeID: String) -> Bool { nodeID == smartID(recentlyDeletedRaw) }

    nonisolated static func includesHidden(raw: Int) -> Bool { raw == hiddenRaw || raw == recentlyDeletedRaw }

    /// Number of pictures in a collection. An estimate of zero is trusted (cheap); otherwise the
    /// pictures-only count is fetched, since the estimate also counts videos.
    nonisolated static func imageCount(in collection: PHAssetCollection, includeHidden: Bool = false) -> Int {
        let estimate = collection.estimatedAssetCount
        if estimate == 0 { return 0 }
        return PHAsset.fetchAssets(in: collection, options: imageOptions(includeHidden: includeHidden)).count
    }

    nonisolated static func userCollections(in list: PHCollectionList?) -> [CollectionSnapshot] {
        let result: PHFetchResult<PHCollection>
        if let list {
            result = PHCollection.fetchCollections(in: list, options: nil)
        } else {
            result = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        }
        var snapshots: [CollectionSnapshot] = []
        for index in 0..<result.count {
            let collection = result.object(at: index)
            let title = collection.localizedTitle ?? "Untitled"
            if let folder = collection as? PHCollectionList {
                snapshots.append(CollectionSnapshot(
                    title: title, identifier: folder.localIdentifier, isFolder: true,
                    children: userCollections(in: folder), assetCount: 0))
            } else if let album = collection as? PHAssetCollection {
                snapshots.append(CollectionSnapshot(
                    title: title, identifier: album.localIdentifier, isFolder: false,
                    children: [], assetCount: imageCount(in: album)))
            }
        }
        return snapshots
    }

    nonisolated private static func smartNode(_ raw: Int, title: String, includeHidden: Bool = false) -> SidebarNode? {
        guard let collection = smartCollection(raw) else { return nil }
        return SidebarNode(id: smartID(raw), title: title, kind: .smart(raw),
                           count: imageCount(in: collection, includeHidden: includeHidden))
    }

    /// The iPhone's first screen: the section structure from collection lists only. Library counts come from
    /// `libraryCount` (three cheap fetches); user albums and shared albums carry no count (the tiles ask for theirs);
    /// media types and utilities list the smart albums that exist, also without counts (a background pass counts them).
    /// Returns the fetch results the caller watches for structural changes.
    nonisolated static func structure(
        filter: LibraryFilter, libraryCount: (String) -> Int
    ) -> (sections: [SidebarSection], watched: [Unchecked<AnyObject>]) {
        var watched: [Unchecked<AnyObject>] = []
        var library = [
            SidebarNode(id: "all", title: "Library", kind: .library, count: libraryCount("all")),
            SidebarNode(id: "fav", title: "Favorites", kind: .favorites, count: libraryCount("fav")),
        ]
        if smartCollection(PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue) != nil {
            library.append(SidebarNode(id: "recent", title: "Recently Saved", kind: .recents, count: libraryCount("recent")))
        }
        func lightCollections(in list: PHCollectionList?) -> [CollectionSnapshot] {
            let result: PHFetchResult<PHCollection> = list.map { PHCollection.fetchCollections(in: $0, options: nil) }
                ?? PHCollectionList.fetchTopLevelUserCollections(with: nil)
            watched.append(Unchecked(value: result))
            var snapshots: [CollectionSnapshot] = []
            for index in 0..<result.count {
                let collection = result.object(at: index)
                let title = collection.localizedTitle ?? "Untitled"
                if let folder = collection as? PHCollectionList {
                    snapshots.append(CollectionSnapshot(title: title, identifier: folder.localIdentifier, isFolder: true,
                                                        children: lightCollections(in: folder), assetCount: 0))
                } else if let album = collection as? PHAssetCollection {
                    // An estimate of zero is trusted (as `imageCount` does); anything else is counted when the tile shows.
                    let empty = album.estimatedAssetCount == 0
                    snapshots.append(CollectionSnapshot(title: title, identifier: album.localIdentifier, isFolder: false,
                                                        children: [], assetCount: 0, assetCountKnown: empty))
                }
            }
            return snapshots
        }
        let albums = SidebarModel.albumNodes(from: lightCollections(in: nil))

        var shared: [SidebarNode] = []
        let sharedResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        watched.append(Unchecked(value: sharedResult))
        for index in 0..<sharedResult.count {
            let album = sharedResult.object(at: index)
            shared.append(SidebarNode(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled", kind: .album,
                                      count: album.estimatedAssetCount == 0 ? 0 : nil))
        }
        let (media, utilities) = smartNodes()
        let sections = SidebarModel.sections(library: library, albums: albums, shared: shared,
                                             mediaTypes: media, utilities: utilities)
        return (sections, watched)
    }

    /// The Media Types and Utilities nodes whose smart albums exist on this device, without counts.
    nonisolated static func smartNodes() -> (media: [SidebarNode], utilities: [SidebarNode]) {
        let mediaTypes: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumVideos, "Videos"), (.smartAlbumSelfPortraits, "Selfies"),
            (.smartAlbumLivePhotos, "Live Photos"), (.smartAlbumDepthEffect, "Portrait"),
            (.smartAlbumPanoramas, "Panoramas"), (.smartAlbumTimelapses, "Time-lapse"),
            (.smartAlbumSlomoVideos, "Slo-mo"), (.smartAlbumBursts, "Bursts"),
            (.smartAlbumScreenshots, "Screenshots"), (.smartAlbumScreenRecordings, "Screen Recordings"),
            (.smartAlbumRAW, "RAW"), (.smartAlbumAnimated, "Animated"),
        ]
        let media = mediaTypes.compactMap { subtype, title -> SidebarNode? in
            smartCollection(subtype.rawValue) == nil ? nil
                : SidebarNode(id: smartID(subtype.rawValue), title: title, kind: .smart(subtype.rawValue))
        }
        var utilities: [SidebarNode] = []
        let generic = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumGeneric, options: nil)
        for index in 0..<generic.count {
            let collection = generic.object(at: index)
            if collection.localizedTitle?.caseInsensitiveCompare("Imports") == .orderedSame {
                utilities.append(SidebarNode(id: collection.localIdentifier, title: "Imports", kind: .album))
                break
            }
        }
        if utilities.isEmpty,
           let imported = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumImported, options: nil).firstObject {
            utilities.append(SidebarNode(id: imported.localIdentifier, title: "Imports", kind: .album))
        }
        if smartCollection(hiddenRaw) != nil { utilities.append(SidebarNode(id: smartID(hiddenRaw), title: "Hidden", kind: .smart(hiddenRaw))) }
        if smartCollection(recentlyDeletedRaw) != nil {
            utilities.append(SidebarNode(id: smartID(recentlyDeletedRaw), title: "Recently Deleted", kind: .smart(recentlyDeletedRaw)))
        }
        return (media, utilities)
    }

    nonisolated static func load() -> [SidebarSection] { loadAll(withAlbumEntries: false).sections }

    /// The user's albums flattened out of the snapshot tree (counts already fetched for the sidebar, so
    /// this adds no second counting pass), with each album's capabilities.
    nonisolated static func albumEntries(from snapshots: [CollectionSnapshot], path: [String] = []) -> [AlbumEntry] {
        var entries: [AlbumEntry] = []
        for snapshot in snapshots {
            if snapshot.isFolder {
                let inner = snapshot.children.compactMap { $0 as? CollectionSnapshot }
                entries += albumEntries(from: inner, path: path + [snapshot.title])
            } else {
                entries.append(AlbumEntry(
                    id: snapshot.identifier, title: snapshot.title, path: path, count: snapshot.assetCount,
                    capabilities: LibraryActions.albumCapabilities(id: snapshot.identifier) ?? .none))
            }
        }
        return entries
    }

    /// `withAlbumEntries: false` skips the per-album capability lookups (one PhotoKit fetch each) for callers that
    /// only want the sections.
    nonisolated static func loadAll(withAlbumEntries: Bool = true) -> (sections: [SidebarSection], albums: [AlbumEntry]) {
        // LIBRARY
        var library = [
            SidebarNode(id: "all", title: "Library", kind: .library,
                        count: PHAsset.fetchAssets(with: imageOptions()).count),
            SidebarNode(id: "fav", title: "Favorites", kind: .favorites,
                        count: PHAsset.fetchAssets(with: favoriteOptions()).count),
        ]
        if let recent = smartCollection(PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue) {
            library.append(SidebarNode(id: "recent", title: "Recently Saved", kind: .recents,
                                       count: imageCount(in: recent)))
        }

        // ALBUMS and SHARED ALBUMS
        // Photos' own manual order: no sorting here or in the builder.
        let tree = userCollections(in: nil)
        let albums = SidebarModel.albumNodes(from: tree)
        var shared: [SidebarNode] = []
        let sharedResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        for index in 0..<sharedResult.count {
            let album = sharedResult.object(at: index)
            shared.append(SidebarNode(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled",
                                      kind: .album, count: imageCount(in: album)))
        }

        // MEDIA TYPES, in Photos' order
        let mediaTypes: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumVideos, "Videos"), (.smartAlbumSelfPortraits, "Selfies"),
            (.smartAlbumLivePhotos, "Live Photos"), (.smartAlbumDepthEffect, "Portrait"),
            (.smartAlbumPanoramas, "Panoramas"), (.smartAlbumTimelapses, "Time-lapse"),
            (.smartAlbumSlomoVideos, "Slo-mo"), (.smartAlbumBursts, "Bursts"),
            (.smartAlbumScreenshots, "Screenshots"), (.smartAlbumScreenRecordings, "Screen Recordings"),
            (.smartAlbumRAW, "RAW"), (.smartAlbumAnimated, "Animated"),
        ]
        let media = mediaTypes.compactMap { smartNode($0.0.rawValue, title: $0.1) }

        // UTILITIES
        var utilities: [SidebarNode] = []
        let generic = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumGeneric, options: nil)
        for index in 0..<generic.count {
            let collection = generic.object(at: index)
            if collection.localizedTitle?.caseInsensitiveCompare("Imports") == .orderedSame {
                utilities.append(SidebarNode(id: collection.localIdentifier, title: "Imports", kind: .album,
                                             count: imageCount(in: collection)))
                break
            }
        }
        if utilities.isEmpty,
           let imported = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumImported, options: nil).firstObject {
            utilities.append(SidebarNode(id: imported.localIdentifier, title: "Imports", kind: .album,
                                         count: imageCount(in: imported)))
        }
        if let hidden = smartNode(hiddenRaw, title: "Hidden", includeHidden: true) { utilities.append(hidden) }
        if let deleted = smartNode(recentlyDeletedRaw, title: "Recently Deleted", includeHidden: true) { utilities.append(deleted) }

        let sections = SidebarModel.sections(library: library, albums: albums, shared: shared,
                                             mediaTypes: media, utilities: utilities)
        return (sections, withAlbumEntries ? albumEntries(from: tree) : [])
    }

    /// The pictures of a sidebar node ("all", "fav", "recent", "smart:<raw>" or an album id), with the filter's fetch criteria.
    nonisolated static func fetchAssets(nodeID id: String, filter: LibraryFilter = LibraryFilter(), limit: Int = 0) -> PHFetchResult<PHAsset> {
        func options(includeHidden: Bool = false, _ f: LibraryFilter) -> PHFetchOptions {
            let o = imageOptions(includeHidden: includeHidden, filter: f)
            if limit > 0 { o.fetchLimit = limit }
            return o
        }
        switch id {
        case "all":
            return PHAsset.fetchAssets(with: options(filter))
        case "fav":
            var f = filter
            f.favoritesOnly = true
            return PHAsset.fetchAssets(with: options(f))
        case "recent":
            if let c = smartCollection(PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue) {
                return PHAsset.fetchAssets(in: c, options: options(filter))
            }
        default:
            if id.hasPrefix("smart:"), let raw = Int(id.dropFirst(6)) {
                if let c = smartCollection(raw) {
                    return PHAsset.fetchAssets(in: c, options: options(includeHidden: includesHidden(raw: raw), filter))
                }
            } else if let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                return PHAsset.fetchAssets(in: c, options: options(filter))
            }
        }
        return PHAsset.fetchAssets(with: options(filter))
    }
}
