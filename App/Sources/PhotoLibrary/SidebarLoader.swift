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
        if filter.scope == .myLibrary { options.includeAssetSourceTypes = [.typeUserLibrary] }
        return options
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

    nonisolated static func load() -> [SidebarSection] {
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
        let albums = SidebarModel.albumNodes(from: userCollections(in: nil))
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

        return SidebarModel.sections(library: library, albums: albums, shared: shared,
                                     mediaTypes: media, utilities: utilities)
    }

    /// The pictures of a sidebar node ("all", "fav", "recent", "smart:<raw>" or an album id), with the filter's fetch criteria.
    nonisolated static func fetchAssets(nodeID id: String, filter: LibraryFilter = LibraryFilter()) -> PHFetchResult<PHAsset> {
        switch id {
        case "all":
            return PHAsset.fetchAssets(with: imageOptions(filter: filter))
        case "fav":
            var f = filter
            f.favoritesOnly = true
            return PHAsset.fetchAssets(with: imageOptions(filter: f))
        case "recent":
            if let c = smartCollection(PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue) {
                return PHAsset.fetchAssets(in: c, options: imageOptions(filter: filter))
            }
        default:
            if id.hasPrefix("smart:"), let raw = Int(id.dropFirst(6)) {
                if let c = smartCollection(raw) {
                    return PHAsset.fetchAssets(in: c, options: imageOptions(includeHidden: includesHidden(raw: raw), filter: filter))
                }
            } else if let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                return PHAsset.fetchAssets(in: c, options: imageOptions(filter: filter))
            }
        }
        return PHAsset.fetchAssets(with: imageOptions(filter: filter))
    }
}
