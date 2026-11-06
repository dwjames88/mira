import AppKit
import MiraCore
import Photos

/// Favorite and hidden state of a set of photos (all / none / mixed collapse to these flags).
struct SelectionFlags: Equatable, Sendable {
    var allFavorite = false
    var allHidden = false
}

/// What the album name sheet is for.
enum AlbumSheetRequest: Identifiable, Equatable {
    /// A new album; these photos go into it (empty: just an album).
    case new(assetIDs: [String])
    case rename(id: String, title: String)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let id, _): "rename:\(id)"
        }
    }
}

// MARK: Selection

extension LibraryStore {
    /// Clears the selection and the cursor (the collection or the filter changed).
    func resetSelection() {
        selection.clear()
        selectedIndex = nil
        anchorIndex = nil
        selectionFlags = SelectionFlags()
        flagsTask?.cancel()
    }

    /// The photo the inspector describes: the last one picked on its own.
    var primaryID: String? { selection.anchor ?? selection.ids.last }

    /// A click on the cell at `index` with the keys held at that moment.
    func handleClick(index: Int, modifiers: LibraryClickModifiers) {
        guard let id = asset(at: index)?.localIdentifier else { return }
        var next = selection
        let usesRange = modifiers.contains(.shift)
        LibraryInteraction.click(&next, id: id, modifiers: modifiers) { rangeIDs(to: index) }
        selection = next
        if !usesRange || anchorIndex == nil { anchorIndex = index }
        if next.isEmpty { anchorIndex = nil }
        selectedIndex = index
        refreshSelectionFlags()
    }

    /// The arrow keys: move the cursor and select just that cell, or with shift extend the range.
    func moveCursor(to index: Int, extend: Bool) {
        handleClick(index: index, modifiers: extend ? .shift : [])
    }

    /// Ids from the range anchor to `index`, in display order; empty when the anchor is not usable.
    private func rangeIDs(to index: Int) -> [String] {
        guard let a = anchorIndex, let anchorID = selection.anchor, asset(at: a)?.localIdentifier == anchorID else { return [] }
        let lower = min(a, index), upper = max(a, index)
        return (lower...upper).compactMap { asset(at: $0)?.localIdentifier }
    }

    func selectAll() {
        guard count > 0 else { return }
        selection.selectAll((0..<count).compactMap { asset(at: $0)?.localIdentifier })
        anchorIndex = 0
        refreshSelectionFlags()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        anchorIndex = nil
        selectionFlags = SelectionFlags()
        flagsTask?.cancel()
    }

    /// Re-reads favorite / hidden for the selection off the main actor (a large selection is a large fetch).
    func refreshSelectionFlags() {
        flagsTask?.cancel()
        let ids = selection.ids
        guard !ids.isEmpty else { selectionFlags = SelectionFlags(); return }
        flagsTask = Task { [weak self] in
            let flags = await Task.detached(priority: .userInitiated) { Self.flags(for: ids) }.value
            guard !Task.isCancelled, let self else { return }
            if self.selection.ids == ids { self.selectionFlags = flags }
        }
    }

    nonisolated static func flags(for ids: [String]) -> SelectionFlags {
        guard !ids.isEmpty else { return SelectionFlags() }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        guard fetch.count > 0 else { return SelectionFlags() }
        var flags = SelectionFlags(allFavorite: true, allHidden: true)
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            if !asset.isFavorite { flags.allFavorite = false }
            if !asset.isHidden { flags.allHidden = false }
            if !flags.allFavorite && !flags.allHidden { break }
        }
        return flags
    }

    // MARK: Availability

    /// Where the user is, for `LibraryActionAvailability`. `ids` is what the action would act on.
    func actionContext(for ids: [String]) -> LibraryActionContext {
        let kind = selectedNode?.kind
        let flags = ids == selection.ids ? selectionFlags : (ids.count <= 500 ? Self.flags(for: ids) : SelectionFlags())
        return LibraryActionContext(
            nodeKind: kind, nodeID: selectedNodeID, isReadOnly: isReadOnlySelection,
            isHiddenAlbum: selectedNodeID == SidebarLoader.smartID(SidebarLoader.hiddenRaw),
            albumCapabilities: kind == .album ? albums.first { $0.id == selectedNodeID }?.capabilities : nil,
            limitedAccess: authorization == .limited,
            selectionCount: ids.count, allFavorite: flags.allFavorite, allHidden: flags.allHidden)
    }

    func actionItems(for ids: [String]) -> [LibraryActionItem] {
        LibraryActionAvailability.items(for: actionContext(for: ids))
    }

    /// Albums that can take photos, minus the one being viewed.
    var albumTargets: [AlbumEntry] {
        AlbumList.targets(for: albums, excluding: selectedNode?.kind == .album ? selectedNodeID : nil)
    }

    var canManageAlbums: Bool { LibraryActionAvailability.canManageAlbums(limitedAccess: authorization == .limited) }

    /// The viewed album when it is a user album the user can take photos out of.
    var currentAlbum: AlbumEntry? {
        guard selectedNode?.kind == .album else { return nil }
        return albums.first { $0.id == selectedNodeID }
    }

    // MARK: Running actions

    /// Runs a Photos write; swallows the user's cancel of Photos' own confirmation and shows any other
    /// failure as a notice. Returns true when it went through.
    @discardableResult
    func attempt(_ what: String, _ work: @Sendable () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            if !LibraryActions.isUserCancel(error) { notify("\(what): \(error.localizedDescription)") }
            return false
        }
    }

    func notify(_ text: String) {
        actionNote = text
        actionNoteTask?.cancel()
        actionNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.actionNote = nil }
        }
    }

    func setFavorite(_ ids: [String], _ on: Bool) {
        Task { await attempt("COULD NOT CHANGE FAVORITE") { try await LibraryActions.setFavorite(ids, on) } }
    }

    func toggleFavorite(_ ids: [String]) {
        let on = !(ids == selection.ids ? selectionFlags : Self.flags(for: ids)).allFavorite
        setFavorite(ids, on)
    }

    func toggleHidden(_ ids: [String]) {
        let on = !(ids == selection.ids ? selectionFlags : Self.flags(for: ids)).allHidden
        Task { await attempt("COULD NOT CHANGE HIDDEN") { try await LibraryActions.setHidden(ids, on) } }
    }

    /// Duplicates; the copies go into the album being viewed, when it takes photos.
    func duplicate(_ ids: [String]) {
        let album = currentAlbum?.capabilities.canAdd == true ? currentAlbum?.id : nil
        Task {
            await attempt("COULD NOT DUPLICATE") {
                let copies = try await LibraryActions.duplicate(ids)
                if let album, !copies.isEmpty { try await LibraryActions.add(copies, toAlbum: album) }
            }
        }
    }

    /// Moves to Recently Deleted after Photos' own confirmation. Returns true when deleted.
    @discardableResult
    func delete(_ ids: [String]) async -> Bool {
        await attempt("COULD NOT DELETE") { try await LibraryActions.delete(ids) }
    }

    func add(_ ids: [String], toAlbum albumID: String) {
        Task { await attempt("COULD NOT ADD TO THE ALBUM") { try await LibraryActions.add(ids, toAlbum: albumID) } }
    }

    func move(_ ids: [String], toAlbum albumID: String) {
        guard let source = currentAlbum?.id else { return }
        Task { await attempt("COULD NOT MOVE") { try await LibraryActions.move(ids, from: source, to: albumID) } }
    }

    func removeFromCurrentAlbum(_ ids: [String]) {
        guard let source = currentAlbum?.id else { return }
        Task { await attempt("COULD NOT REMOVE FROM THE ALBUM") { try await LibraryActions.remove(ids, fromAlbum: source) } }
    }

    /// Creates the album (with the photos in it, when there are any).
    func createAlbum(title: String, adding ids: [String]) async -> Bool {
        await attempt("COULD NOT CREATE THE ALBUM") {
            if ids.isEmpty { _ = try await LibraryActions.createAlbum(title: title) } else {
                _ = try await LibraryActions.addToNewAlbum(ids, title: title)
            }
        }
    }

    func renameAlbum(id: String, title: String) async -> Bool {
        await attempt("COULD NOT RENAME THE ALBUM") { try await LibraryActions.renameAlbum(id: id, title: title) }
    }

    func deleteAlbum(_ album: AlbumEntry) {
        Task { await attempt("COULD NOT DELETE THE ALBUM") { try await LibraryActions.deleteAlbum(id: album.id) } }
    }

    /// Opens the New Album sheet; `ids` go into the album.
    func beginNewAlbum(adding ids: [String] = []) {
        guard canManageAlbums else { return }
        albumSheet = .new(assetIDs: ids)
    }

    func beginRename(_ album: AlbumEntry) {
        guard canManageAlbums, album.capabilities.canRename else { return }
        albumSheet = .rename(id: album.id, title: album.title)
    }

    func beginDelete(_ album: AlbumEntry) {
        guard canManageAlbums, album.capabilities.canDelete else { return }
        albumPendingDeletion = album
    }

    /// The `+` and context-menu rules for a sidebar node: the user album behind it, when it is one.
    func album(forNode node: SidebarNode) -> AlbumEntry? {
        node.kind == .album ? albums.first { $0.id == node.id } : nil
    }

    /// A drop of photos on a sidebar row: into a user album that takes content, or onto Favorites.
    func canAcceptDrop(on node: SidebarNode) -> Bool {
        guard authorization == .authorized else { return false }
        if node.kind == .favorites { return true }
        return album(forNode: node)?.capabilities.canAdd == true
    }

    func acceptDrop(_ ids: [String], on node: SidebarNode) {
        guard canAcceptDrop(on: node), !ids.isEmpty else { return }
        if node.kind == .favorites { setFavorite(ids, true) } else { add(ids, toAlbum: node.id) }
    }

    // MARK: Share

    /// Writes the pictures to temporary files and opens the share sheet at the pointer.
    func share(_ ids: [String]) {
        Task {
            let urls = await LibrarySharing.stage(ids)
            guard !urls.isEmpty else { notify("NOTHING TO SHARE"); return }
            LibrarySharing.present(urls)
        }
    }

    /// Dispatches a menu or header action. Sheets and pickers that need a choice are driven by the views.
    func perform(_ action: LibraryAction, on ids: [String]) {
        switch action {
        case .favorite: setFavorite(ids, true)
        case .unfavorite: setFavorite(ids, false)
        case .hide, .unhide: toggleHidden(ids)
        case .duplicate: duplicate(ids)
        case .info: inspectorOpen = true
        case .share: share(ids)
        case .delete: Task { await delete(ids) }
        case .removeFromAlbum: removeFromCurrentAlbum(ids)
        case .addToAlbum, .moveToAlbum: break
        }
    }
}

// MARK: Sharing

/// Stages originals (or the edited render) as files so the share sheet can hand them to Mail, Messages and AirDrop.
enum LibrarySharing {
    nonisolated static func stage(_ ids: [String]) async -> [URL] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        guard fetch.count > 0 else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-library-share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return [] }
        var urls: [URL] = []
        for index in 0..<fetch.count {
            let resources = PHAssetResource.assetResources(for: fetch.object(at: index))
            let original = resources.first { $0.type == .photo } ?? resources.first { $0.type == .alternatePhoto }
            let chosen = resources.first { $0.type == .fullSizePhoto } ?? original
            guard let chosen else { continue }
            var name = chosen.originalFilename
            if let original, chosen.type == .fullSizePhoto {
                let ext = (chosen.originalFilename as NSString).pathExtension
                let base = (original.originalFilename as NSString).deletingPathExtension
                name = ext.isEmpty ? base : "\(base).\(ext)"
            }
            let url = directory.appendingPathComponent("\(index)-\(name)")
            if (try? await write(chosen, to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    private nonisolated static func write(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Removes share files left by earlier launches.
    nonisolated static func removeStale() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-library-share", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor private static var picker: NSSharingServicePicker?

    /// Opens the picker at the pointer (the menu that started it is gone by now).
    @MainActor static func present(_ urls: [URL]) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        Self.picker = picker
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = content.convert(point, from: nil)
        picker.show(relativeTo: NSRect(x: local.x, y: local.y, width: 1, height: 1), of: content, preferredEdge: .minY)
    }
}
