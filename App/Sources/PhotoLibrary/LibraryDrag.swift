import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

extension View {
    /// Grid cells drag the selection when the dragged cell is part of it, else just themselves.
    func libraryDraggable(store: LibraryStore, id: String?) -> some View {
        modifier(LibraryDragSource(store: store, id: id))
    }

    /// Sidebar rows: drop photos on an album that takes them (or Favorites), and the album's context menu.
    func sidebarLibraryActions(store: LibraryStore, node: SidebarNode) -> some View {
        modifier(SidebarRowActions(store: store, node: node))
    }
}

private struct LibraryDragSource: ViewModifier {
    let store: LibraryStore
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.draggable(LibraryDragPayload.encode(LibraryInteraction.dragIDs(dragged: id, selection: store.selection)))
        } else {
            content
        }
    }
}

private struct SidebarRowActions: ViewModifier {
    let store: LibraryStore
    let node: SidebarNode
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                if targeted { Rectangle().fill(T.lichen).frame(width: 2) }
            }
            .background(targeted ? T.hair : Color.clear)
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(LibraryDragPayload.decode).first
                guard let ids, store.canAcceptDrop(on: node) else { return false }
                store.acceptDrop(ids, on: node)
                return true
            } isTargeted: { over in
                targeted = over && store.canAcceptDrop(on: node)
            }
            .contextMenu { SidebarContextMenu(store: store, node: node) }
    }
}

/// Right-click on a sidebar row: Rename…, Delete Album… (user albums that allow it) and New Album….
struct SidebarContextMenu: View {
    let store: LibraryStore
    let node: SidebarNode

    var body: some View {
        if store.canManageAlbums, !node.isFolder, store.authorization == .authorized {
            if let album = store.album(forNode: node) {
                Button("Rename\u{2026}") { store.beginRename(album) }
                    .disabled(!album.capabilities.canRename)
                Button("Delete Album\u{2026}", role: .destructive) { store.beginDelete(album) }
                    .disabled(!album.capabilities.canDelete)
                Divider()
            }
            Button("New Album\u{2026}") { store.beginNewAlbum() }
        }
    }
}
