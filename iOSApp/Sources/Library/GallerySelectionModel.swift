import MiraCore
import Photos
import SwiftUI

/// What the album sheet is for: it carries the assets it acts on.
struct AlbumSheetRequest: Identifiable, Equatable {
    enum Mode: Equatable { case add, move }
    let id = UUID()
    var mode: Mode
    var assetIDs: [String]
    /// The album the assets come from (MOVE) or that the sheet must leave out of the list.
    var sourceAlbumID: String?
    /// Ends select mode when the sheet's action completes (MOVE).
    var endsSelection: Bool { mode == .move }
}

struct InfoSheetRequest: Identifiable, Equatable {
    let id = UUID()
    var assetID: String
}

/// Selection, action availability and action execution for one album grid. Views read it; it never
/// holds PhotoKit objects (ids only), so every write goes through `LibraryActions`.
@MainActor @Observable
final class GallerySelectionModel {
    let nodeID: String
    var selection = LibrarySelection()
    private(set) var allFavorite = false
    private(set) var allHidden = false
    private(set) var capabilities: AlbumCapabilities?
    var albumRequest: AlbumSheetRequest?
    var infoRequest: InfoSheetRequest?
    /// "PREPARING n" while shared images load.
    private(set) var preparing: Int?
    /// A short mono message at the bottom (errors, the share cap).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var flagsTask: Task<Void, Never>?

    init(nodeID: String) { self.nodeID = nodeID }

    var isSelecting: Bool { selection.isSelecting }

    // MARK: Context

    nonisolated static func nodeKind(of nodeID: String) -> SidebarNodeKind {
        switch nodeID {
        case "all": return .library
        case "fav": return .favorites
        case "recent": return .recents
        default:
            if nodeID.hasPrefix("smart:"), let raw = Int(nodeID.dropFirst(6)) { return .smart(raw) }
            return .album
        }
    }

    /// The input to `LibraryActionAvailability` for a grid and a selection (pure, testable).
    nonisolated static func context(nodeID: String, limitedAccess: Bool, capabilities: AlbumCapabilities?, count: Int,
                                    allFavorite: Bool, allHidden: Bool) -> LibraryActionContext {
        LibraryActionContext(
            nodeKind: nodeKind(of: nodeID), nodeID: nodeID,
            isReadOnly: SidebarLoader.isReadOnly(nodeID: nodeID),
            isHiddenAlbum: nodeID == SidebarLoader.smartID(SidebarLoader.hiddenRaw),
            albumCapabilities: nodeKind(of: nodeID) == .album ? capabilities : nil,
            limitedAccess: limitedAccess, selectionCount: count, allFavorite: allFavorite, allHidden: allHidden)
    }

    func items(limited: Bool) -> [LibraryActionItem] {
        LibraryActionAvailability.items(for: Self.context(
            nodeID: nodeID, limitedAccess: limited, capabilities: capabilities, count: selection.count,
            allFavorite: allFavorite, allHidden: allHidden))
    }

    /// Menu items for one asset (the context menu), independent of the selection.
    func items(for asset: PHAsset, limited: Bool) -> [LibraryActionItem] {
        LibraryActionAvailability.items(for: Self.context(
            nodeID: nodeID, limitedAccess: limited, capabilities: capabilities, count: 1,
            allFavorite: asset.isFavorite, allHidden: asset.isHidden))
    }

    func loadCapabilities() async {
        guard Self.nodeKind(of: nodeID) == .album, capabilities == nil else { return }
        let id = nodeID
        capabilities = await Task.detached { LibraryActions.albumCapabilities(id: id) }.value
    }

    /// Re-reads favorite / hidden for the selection (after a selection or library change).
    func refreshFlags() {
        flagsTask?.cancel()
        let ids = selection.ids
        guard !ids.isEmpty else { allFavorite = false; allHidden = false; return }
        flagsTask = Task { [weak self] in
            let flags = await GalleryKit.detached(priority: .userInitiated) { Self.flags(of: ids) }
            guard !Task.isCancelled, let self else { return }
            allFavorite = flags.favorite
            allHidden = flags.hidden
        }
    }

    private nonisolated static func flags(of ids: [String]) -> (favorite: Bool, hidden: Bool) {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        guard result.count > 0 else { return (false, false) }
        var favorite = true, hidden = true
        for index in 0..<result.count {
            // A newer tap supersedes this read (its caller drops the answer): stop walking a long selection.
            if index % 512 == 0, Task.isCancelled { break }
            let asset = result.object(at: index)
            if !asset.isFavorite { favorite = false }
            if !asset.isHidden { hidden = false }
        }
        return (favorite, hidden)
    }

    // MARK: Selection

    func beginSelecting() { selection.isSelecting = true }
    func finishSelecting() { selection.finishSelecting(); allFavorite = false; allHidden = false }

    /// A tap on a cell. True when it was consumed as a selection toggle.
    func handleTap(_ asset: PHAsset) -> Bool {
        guard selection.isSelecting else { return false }
        selection.toggle(asset.localIdentifier)
        refreshFlags()
        return true
    }

    func selectAll(_ result: PHFetchResult<PHAsset>?) {
        guard let result else { return }
        let box = Unchecked(value: result)
        Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { GalleryKit.identifiers(of: box) }.value
            guard let self, selection.isSelecting else { return }
            selection.selectAll(ids)
            refreshFlags()
        }
    }

    func selectNone() { selection.clear(); allFavorite = false; allHidden = false }

    /// Assets left the album (deleted, removed, hidden): drop them from the selection.
    /// `removed` nil means the change was not incremental: re-check the whole selection against `result`.
    func membershipChanged(removed: [String]?, result: PHFetchResult<PHAsset>?) {
        guard !selection.isEmpty else { return }
        if let removed {
            guard !removed.isEmpty else { return }
            selection.prune(keeping: Set(selection.ids).subtracting(removed))
        } else if let result {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            let present = PHAsset.fetchAssets(withLocalIdentifiers: selection.ids, options: options)
            var keep = Set<String>()
            for index in 0..<present.count {
                let asset = present.object(at: index)
                if result.contains(asset) { keep.insert(asset.localIdentifier) }
            }
            selection.prune(keeping: keep)
        }
        refreshFlags()
    }

    // MARK: Notices

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Actions

    /// Runs an action on `ids` (the selection, or one cell's asset from the context menu).
    func perform(_ action: LibraryAction, on ids: [String], fromSelection: Bool) {
        guard !ids.isEmpty else { return }
        let node = nodeID
        let finish = finisher(fromSelection)
        switch action {
        case .favorite, .unfavorite:
            let on = action == .favorite
            run { try await LibraryActions.setFavorite(ids, on) }
        case .hide, .unhide:
            let on = action == .hide
            run { try await LibraryActions.setHidden(ids, on) }
        case .duplicate:
            run { _ = try await LibraryActions.duplicate(ids) }
        case .delete:
            run(then: finish) { try await LibraryActions.delete(ids) }
        case .removeFromAlbum:
            run(then: finish) { try await LibraryActions.remove(ids, fromAlbum: node) }
        case .addToAlbum:
            albumRequest = AlbumSheetRequest(mode: .add, assetIDs: ids, sourceAlbumID: node)
        case .moveToAlbum:
            albumRequest = AlbumSheetRequest(mode: .move, assetIDs: ids, sourceAlbumID: node)
        case .info:
            if let id = ids.first { infoRequest = InfoSheetRequest(assetID: id) }
        case .share:
            Task { [weak self] in await self?.share(ids) }
        }
    }

    /// Album sheet outcome. `target` nil creates a new album named `newTitle`.
    func complete(_ request: AlbumSheetRequest, target: String?, newTitle: String?) {
        let ids = request.assetIDs
        let source = request.sourceAlbumID.flatMap { Self.nodeKind(of: $0) == .album ? $0 : nil }
        let mode = request.mode
        let ends = request.endsSelection && selection.isSelecting
        let finish = finisher(ends)
        run(then: finish) {
            if let target {
                if mode == .move, let source {
                    try await LibraryActions.move(ids, from: source, to: target)
                } else {
                    try await LibraryActions.add(ids, toAlbum: target)
                }
            } else if let newTitle {
                _ = try await LibraryActions.addToNewAlbum(ids, title: newTitle)
                if mode == .move, let source { try await LibraryActions.remove(ids, fromAlbum: source) }
            }
        }
    }

    private func finisher(_ when: Bool) -> (@MainActor @Sendable () -> Void)? {
        guard when else { return nil }
        return { [weak self] in self?.finishSelecting() }
    }

    private func run(then: (@MainActor @Sendable () -> Void)? = nil, _ work: @escaping @Sendable () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
                then?()
            } catch {
                if LibraryActions.isUserCancel(error) { return }
                self?.show(error.localizedDescription)
            }
        }
    }

    private func share(_ ids: [String]) async {
        preparing = min(ids.count, LibraryShare.cap)
        let result = await LibraryShare.prepare(ids: ids)
        preparing = nil
        if result.urls.isEmpty {
            try? FileManager.default.removeItem(at: result.directory)
            show("NOTHING TO SHARE")
            return
        }
        if result.truncated { show("SHARING THE FIRST \(LibraryShare.cap)") }
        LibraryShare.present(urls: result.urls, directory: result.directory)
    }
}
