import MiraCore
import MiraUI
import Photos
import SwiftUI

private typealias T = FieldFramesTheme

extension View {
    /// Library behaviour for a grid cell: the favorite chip, the selected state and the long-press menu.
    /// `showsFavorite` is off where the cell already uses the bottom-trailing corner (the Develop queue's check).
    func libraryCell(_ library: GallerySelectionModel, asset: PHAsset, gallery: GalleryModel,
                     showsFavorite: Bool = true) -> some View {
        modifier(LibraryCellModifier(library: library, asset: asset, limited: gallery.status == .limited,
                                     showsFavorite: showsFavorite))
    }

    /// Selection bar, sheets, progress and notices around an album grid.
    /// `album` is nil for grids that are not a PhotoKit album (the Develop queue prunes its selection itself).
    func libraryChrome(_ library: GallerySelectionModel, album: AlbumModel?, gallery: GalleryModel) -> some View {
        modifier(LibraryChromeModifier(library: library, album: album, gallery: gallery))
    }
}

private struct LibraryCellModifier: ViewModifier {
    let library: GallerySelectionModel
    let asset: PHAsset
    let limited: Bool
    let showsFavorite: Bool
    private let develop = DevelopStore.shared

    func body(content: Content) -> some View {
        let id = asset.localIdentifier
        let selected = library.selection.contains(id)
        content
            .overlay(alignment: .bottomTrailing) {
                if showsFavorite, asset.isFavorite { LibraryFavoriteChip().padding(4) }
            }
            .overlay { if selected { LibrarySelectedOverlay() } }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                if !library.isSelecting {
                    ForEach(library.items(for: asset, limited: limited)) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            library.perform(item.action, on: [id], fromSelection: false)
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                    Divider()
                    let queued = develop.contains(id)
                    Button { develop.toggle(id) } label: {
                        Label(queued ? "Remove from Develop" : "Add to Develop",
                              systemImage: queued ? "minus.circle" : "plus.circle")
                    }
                }
            }
    }
}

private struct LibraryChromeModifier: ViewModifier {
    let library: GallerySelectionModel
    let album: AlbumModel?
    let gallery: GalleryModel

    /// Keeps the selection in step with the album: ids that leave it are pruned.
    private static func hook(library: GallerySelectionModel, album: AlbumModel?) {
        guard let album else { return }
        album.onMembershipChange = { [weak library, weak album] removed in
            library?.membershipChanged(removed: removed, result: album?.result)
        }
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if library.isSelecting {
                    LibrarySelectionBar(items: library.items(limited: gallery.status == .limited)) { action in
                        library.perform(action, on: library.selection.ids, fromSelection: true)
                        // Favorite and hide keep the selection (hide removes the photos from this view, which prunes them).
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let n = library.preparing {
                        LibraryNoticeLine(text: "PREPARING \(n)")
                    } else if let notice = library.notice {
                        LibraryNoticeLine(text: notice)
                    }
                }
                .padding(.bottom, library.isSelecting ? 64 : 16)
                .allowsHitTesting(false)
            }
            .sheet(item: Bindable(library).albumRequest) { request in
                AlbumPickerHost(request: request) { target, newTitle in
                    library.complete(request, target: target, newTitle: newTitle)
                }
            }
            .sheet(item: Bindable(library).infoRequest) { request in
                AssetInfoHost(assetID: request.assetID)
            }
            .task { await library.loadCapabilities() }
            .onAppear { Self.hook(library: library, album: album) }
            .onChange(of: gallery.changeCount) { _, _ in library.refreshFlags() }
            .animation(.snappy(duration: 0.2), value: library.isSelecting)
    }
}
