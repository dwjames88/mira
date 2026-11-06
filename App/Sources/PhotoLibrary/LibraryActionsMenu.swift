import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

extension LibraryAction {
    /// The title in a system menu: sentence case (the in-UI buttons use `title`, mono uppercase).
    var menuTitle: String {
        switch self {
        case .favorite: "Favorite"
        case .unfavorite: "Unfavorite"
        case .addToAlbum: "Add to Album"
        case .moveToAlbum: "Move to Album"
        case .removeFromAlbum: "Remove from Album"
        case .hide: "Hide"
        case .unhide: "Unhide"
        case .duplicate: "Duplicate"
        case .info: "Get Info"
        case .share: "Share\u{2026}"
        case .delete: "Delete\u{2026}"
        }
    }
}

// MARK: Context menu

/// The right-click menu of a grid cell. Acts on the selection when the cell is part of it, else on that cell.
struct LibraryContextMenu: View {
    let state: AppState
    let index: Int
    let id: String
    var store: LibraryStore { state.store }

    var body: some View {
        let ids = LibraryInteraction.actionIDs(clicked: id, selection: store.selection)
        let items = store.actionItems(for: ids)
        Button("Open") { state.openAsset(at: index) }
            .disabled(ids.count != 1)
        Divider()
        ForEach(items) { item in
            if item.action == .hide || item.action == .unhide || item.action == .info || item.action == .delete {
                Divider()
            }
            switch item.action {
            case .addToAlbum:
                AlbumMenu(title: item.action.menuTitle, store: store, ids: ids, mode: .add)
                    .disabled(!item.isEnabled)
            case .moveToAlbum:
                AlbumMenu(title: item.action.menuTitle, store: store, ids: ids, mode: .move)
                    .disabled(!item.isEnabled)
            case .info:
                Button(item.action.menuTitle) { getInfo(ids: ids) }
                    .disabled(!item.isEnabled)
            case .delete, .removeFromAlbum:
                Button(item.action.menuTitle, systemImage: item.systemImage, role: .destructive) {
                    store.perform(item.action, on: ids)
                }
                .disabled(!item.isEnabled)
            default:
                Button(item.action.menuTitle, systemImage: item.systemImage) { store.perform(item.action, on: ids) }
                    .disabled(!item.isEnabled)
            }
        }
    }

    /// INFO describes one photo: the clicked cell becomes the selection when it was not part of it.
    private func getInfo(ids: [String]) {
        if !store.selection.contains(id) { store.handleClick(index: index, modifiers: []) }
        store.inspectorOpen = true
    }
}

/// "Add to Album ▸" and "Move to Album ▸": New Album… first (add only), then the albums that take photos.
struct AlbumMenu: View {
    enum Mode { case add, move }
    let title: String
    let store: LibraryStore
    let ids: [String]
    let mode: Mode

    var body: some View {
        Menu(title) {
            if mode == .add, store.canManageAlbums {
                Button("New Album\u{2026}") { store.beginNewAlbum(adding: ids) }
                if !store.albumTargets.isEmpty { Divider() }
            }
            ForEach(store.albumTargets) { album in
                Button(album.displayPath) {
                    if mode == .add { store.add(ids, toAlbum: album.id) } else { store.move(ids, toAlbum: album.id) }
                }
            }
        }
    }
}

// MARK: Header actions

/// FAVORITE · ALBUM ▾ · INFO · DELETE at the trailing side of the grid header, shown while something is selected.
struct LibraryHeaderActions: View {
    let store: LibraryStore
    @State private var albumsOpen = false

    var body: some View {
        let ids = store.selection.ids
        let items = store.actionItems(for: ids)
        HStack(spacing: T.cells(1)) {
            ForEach(items.filter { Self.headerActions.contains($0.action) }) { item in
                switch item.action {
                case .addToAlbum:
                    Button { albumsOpen.toggle() } label: { Text("Album \u{25BE}") }
                        .buttonStyle(.ff)
                        .disabled(!item.isEnabled)
                        .popover(isPresented: $albumsOpen, arrowEdge: .bottom) {
                            AlbumPickerPopover(store: store, ids: ids) { albumsOpen = false }
                                .presentationBackground(T.inkSoft)
                        }
                        .accessibilityLabel("Add to album")
                case .info:
                    Button { store.inspectorOpen.toggle() } label: { Text(item.title) }
                        .buttonStyle(FFButtonStyle(prominent: store.inspectorOpen))
                        .accessibilityLabel(store.inspectorOpen ? "Hide info" : "Show info")
                default:
                    Button { store.perform(item.action, on: ids) } label: { Text(item.title) }
                        .buttonStyle(.ff)
                        .disabled(!item.isEnabled)
                        .accessibilityLabel(item.action.menuTitle)
                }
            }
        }
    }

    private static let headerActions: Set<LibraryAction> = [.favorite, .unfavorite, .addToAlbum, .info, .delete]
}

/// The ALBUM ▾ popover: a filter field, NEW ALBUM…, then the albums that take photos. Ink panel, mono labels, no materials.
struct AlbumPickerPopover: View {
    let store: LibraryStore
    let ids: [String]
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        let albums = AlbumList.filter(store.albumTargets, query: query)
        VStack(alignment: .leading, spacing: T.rows(0.5)) {
            FFSectionLabel("Add to album", trailing: ids.count > 1 ? "\(ids.count)" : nil)
            TextField("", text: $query, prompt: Text("FILTER ALBUMS").font(T.mono(10)).foregroundColor(T.paperDim))
                .textFieldStyle(.plain)
                .font(T.mono(11))
                .foregroundStyle(T.paper)
                .padding(.horizontal, T.cells(1))
                .frame(height: T.rows(2))
                .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
                .accessibilityLabel("Filter albums")
            if store.canManageAlbums {
                row("New Album\u{2026}", accent: true) {
                    dismiss()
                    store.beginNewAlbum(adding: ids)
                }
            }
            if albums.isEmpty {
                Text(store.albumTargets.isEmpty ? "NO ALBUMS YET" : "NO MATCH").ffLabel(size: 10)
                    .frame(height: T.rows(1.5), alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(albums) { album in
                            row(album.displayPath, count: album.count) {
                                dismiss()
                                store.add(ids, toAlbum: album.id)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(albums.count), 8) * T.rows(2))
            }
        }
        .padding(T.cells(2))
        .frame(width: T.cells(36))
        .ffPanel()
    }

    private func row(_ title: String, count: Int? = nil, accent: Bool = false, action: @escaping () -> Void) -> some View {
        PickerRow(title: title, count: count, accent: accent, action: action)
    }
}

private struct PickerRow: View {
    let title: String
    let count: Int?
    let accent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.cells(1)) {
                Text(title)
                    .font(accent ? T.mono(11) : .system(size: 13))
                    .tracking(accent ? 11 * T.labelTracking : 0)
                    .textCase(accent ? .uppercase : nil)
                    .foregroundStyle(accent ? T.lichen : (hovering ? T.paper : T.paperMid))
                    .lineLimit(1)
                Spacer(minLength: T.cells(1))
                if let count { Text("\(count)").ffLabel(size: 10) }
            }
            .padding(.horizontal, T.cells(1))
            .frame(height: T.rows(2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? T.hair : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
