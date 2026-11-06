import MiraCore
import MiraUI
import Photos
import SwiftUI

private typealias T = FieldFramesTheme

/// Follows one asset's favorite flag: read on appear, refreshed on each library change.
@MainActor @Observable
final class EditorFavoriteWatcher: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var isFavorite = false
    @ObservationIgnored private var assetID: String?
    @ObservationIgnored private var observing = false

    func watch(_ id: String?) {
        assetID = id
        if id != nil, !observing { PHPhotoLibrary.shared().register(self); observing = true }
        refresh()
    }

    func set(_ value: Bool) { isFavorite = value }

    func refresh() {
        guard let id = assetID else { isFavorite = false; return }
        Task { [weak self] in
            let value = await Task.detached { LibraryActions.isFavorite(id: id) }.value
            guard let self, assetID == id else { return }
            isFavorite = value ?? false
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}

/// Heart and a menu in the editor header, shown only when the open photo is a library asset.
struct EditorLibraryMenu: View {
    let model: EditorViewModel
    @State private var watcher = EditorFavoriteWatcher()
    @State private var albumRequest: AlbumSheetRequest?
    @State private var infoRequest: InfoSheetRequest?

    var body: some View {
        let id = model.libraryAssetID
        HStack(spacing: 0) {
            if let id {
                Button { toggleFavorite(id) } label: {
                    Image(systemName: watcher.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(watcher.isFavorite ? T.lichen : T.paperMid)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watcher.isFavorite ? "Unfavorite" : "Favorite")
                .accessibilityIdentifier("editor.favorite")
                Menu {
                    Button { albumRequest = AlbumSheetRequest(mode: .add, assetIDs: [id], sourceAlbumID: nil) } label: {
                        Label("ADD TO ALBUM…", systemImage: LibraryAction.addToAlbum.systemImage)
                    }
                    Button { infoRequest = InfoSheetRequest(assetID: id) } label: {
                        Label("INFO", systemImage: LibraryAction.info.systemImage)
                    }
                } label: {
                    Text("•••").ffLabel(size: 12, color: T.paperMid, weight: .medium)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Photo actions")
                .accessibilityIdentifier("editor.libraryMenu")
            }
        }
        .task(id: id) { watcher.watch(id) }
        .sheet(item: $albumRequest) { request in
            AlbumPickerHost(request: request) { target, newTitle in
                let ids = request.assetIDs
                Task {
                    do {
                        if let target { try await LibraryActions.add(ids, toAlbum: target) }
                        else if let newTitle { _ = try await LibraryActions.addToNewAlbum(ids, title: newTitle) }
                    } catch {}
                }
            }
        }
        .sheet(item: $infoRequest) { request in AssetInfoHost(assetID: request.assetID) }
    }

    private func toggleFavorite(_ id: String) {
        let on = !watcher.isFavorite
        watcher.set(on)
        Task {
            do { try await LibraryActions.setFavorite([id], on) }
            catch { watcher.refresh() }
        }
    }
}
