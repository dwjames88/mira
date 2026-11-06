import MiraCore
import MiraUI
import Photos

/// What the Photo menu and the editor strip do to the library: on the grid selection in library mode,
/// on the open picture in the editor.
extension AppState {
    func openAsset(at index: Int) {
        guard let asset = store.asset(at: index) else { return }
        openAsset(asset, readOnly: store.isReadOnlySelection)
    }

    var openAssetID: String? {
        if case .asset(let session) = target { session.asset.localIdentifier } else { nil }
    }

    /// The photos a Photo-menu command acts on.
    var photoCommandIDs: [String] {
        switch mode {
        case .library: store.selection.ids
        case .editor: openAssetID.map { [$0] } ?? []
        }
    }

    /// Shortcuts must not reach the photos while a text field or a dialog has the keys.
    private var photoCommandsBlocked: Bool {
        store.albumSheet != nil || store.albumPendingDeletion != nil || store.filterPanelOpen || showExportSheet
            || showRevertConfirm || showLeaveDialog || openFailure != nil || isBusy || isCropping
            || editor?.presetSheet != nil
    }

    /// The menu's actions with their enabled state for the current target.
    var photoItems: [LibraryActionItem] {
        guard store.isAuthorized, !photoCommandsBlocked else { return [] }
        let ids = photoCommandIDs
        switch mode {
        case .library:
            return store.actionItems(for: ids)
        case .editor:
            guard case .asset(let session) = target else { return [] }
            let flags = LibraryStore.flags(for: ids)
            let context = LibraryActionContext(
                isReadOnly: session.isReadOnly, limitedAccess: store.authorization == .limited,
                selectionCount: ids.count, allFavorite: flags.allFavorite, allHidden: flags.allHidden)
            return LibraryActionAvailability.items(for: context)
        }
    }

    func photoEnabled(_ actions: LibraryAction...) -> Bool {
        photoItems.contains { actions.contains($0.action) && $0.isEnabled }
    }

    /// True when the next Favorite command would unfavorite.
    var photoIsFavorite: Bool { photoItems.contains { $0.action == .unfavorite } }
    var photoIsHidden: Bool { photoItems.contains { $0.action == .unhide } }

    var canManagePhotoAlbums: Bool { store.isAuthorized && store.canManageAlbums && !photoCommandsBlocked }

    func runPhotoCommand(_ action: LibraryAction) {
        if action == .info {
            if mode == .library { store.inspectorOpen.toggle() }
            return
        }
        let ids = photoCommandIDs
        guard !ids.isEmpty else { return }
        switch action {
        case .info:
            break
        case .delete:
            Task {
                if await store.delete(ids), mode == .editor { showLibrary() }
            }
        case .addToAlbum, .moveToAlbum:
            break
        default:
            store.perform(action, on: ids)
        }
    }

    // MARK: Editor strip

    /// Whether the open picture is a favorite, re-read after every library change.
    var openAssetIsFavorite: Bool {
        _ = store.changeTick
        return openAssetID.flatMap { LibraryActions.isFavorite(id: $0) } ?? false
    }

    /// The heart and ALBUM menu on the editor strip; nil for files from disk, Recently Deleted and
    /// before Photos access.
    var editorLibraryControls: EditorHostBar.Library? {
        guard case .asset(let session) = target, store.isAuthorized, !session.isReadOnly else { return nil }
        let id = session.asset.localIdentifier
        return EditorHostBar.Library(
            isFavorite: openAssetIsFavorite,
            toggleFavorite: { [self] in store.setFavorite([id], !openAssetIsFavorite) },
            albums: { [self] in
                AlbumList.targets(for: store.albums).map { .init(id: $0.id, title: $0.displayPath) }
            },
            addToAlbum: { [self] album in store.add([id], toAlbum: album) },
            newAlbum: { [self] in store.beginNewAlbum(adding: [id]) },
            showsAlbums: store.canManageAlbums)
    }
}
