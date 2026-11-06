import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// The bar under the grid while selecting: on ink-soft with grain, a hairline on top, mono actions.
/// Takes plain values (availability items and a closure) so a snapshot can render it with stubs.
struct LibrarySelectionBar: View {
    let items: [LibraryActionItem]
    var onAction: (LibraryAction) -> Void

    /// The four that sit on the bar; INFO takes their place when it is all there is (Recently Deleted).
    private static let primaryActions: [LibraryAction] = [.favorite, .unfavorite, .addToAlbum, .delete, .share]

    private var primary: [LibraryActionItem] {
        let main = items.filter { Self.primaryActions.contains($0.action) }
        return main.isEmpty ? items.filter { $0.action == .info } : main
    }

    private var more: [LibraryActionItem] {
        let onBar = Set(primary.map(\.action))
        return items.filter { !onBar.contains($0.action) }
    }

    static func barTitle(_ action: LibraryAction) -> String { action == .addToAlbum ? "ALBUM" : action.title }

    var body: some View {
        VStack(spacing: 0) {
            FFHairline()
            HStack(spacing: 0) {
                ForEach(primary) { item in
                    Button { onAction(item.action) } label: {
                        Text(Self.barTitle(item.action))
                            .ffLabel(size: 10, color: item.isEnabled ? T.paper : T.paperDim, weight: .medium)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                    .accessibilityLabel(item.title.capitalized)
                    .accessibilityIdentifier("library.bar.\(item.action.rawValue)")
                }
                if !more.isEmpty {
                    Menu {
                        ForEach(more) { item in
                            Button(role: item.isDestructive ? .destructive : nil) { onAction(item.action) } label: {
                                Label(item.title, systemImage: item.systemImage)
                            }
                            .disabled(!item.isEnabled)
                        }
                    } label: {
                        Text("•••").ffLabel(size: 12, color: T.paperMid, weight: .medium)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More actions")
                    .accessibilityIdentifier("library.bar.more")
                }
            }
            .padding(.horizontal, T.cells(1))
        }
        .background { FFPanelBackground() }
    }
}

/// The mono "N SELECTED" status plus ALL / NONE in the grid's header while selecting.
struct LibrarySelectionStatus: View {
    let count: Int
    /// Whether ALL is offered (it is not while the RAW filter shows a subset).
    var canSelectAll = true
    var onAll: () -> Void = {}
    var onNone: () -> Void = {}

    var body: some View {
        HStack(spacing: T.cells(1.5)) {
            Text("\(count) SELECTED").ffLabel(size: 9, color: T.lichen).lineLimit(1)
                .accessibilityIdentifier("library.selectedCount")
            if canSelectAll {
                Button(action: onAll) { Text("ALL").ffLabel(size: 9, color: T.paperMid).frame(minWidth: 28, minHeight: 44) }
                    .buttonStyle(.plain)
            }
            if count > 0 {
                Button(action: onNone) { Text("NONE").ffLabel(size: 9, color: T.paperMid).frame(minWidth: 28, minHeight: 44) }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// SELECT, or DONE in lichen while selecting.
struct LibrarySelectToggle: View {
    let isSelecting: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(isSelecting ? "DONE" : "SELECT")
                .ffLabel(size: 11, color: isSelecting ? T.lichen : T.paperDim)
                .lineLimit(1)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelecting ? "Done selecting" : "Select photos")
        .accessibilityIdentifier("library.select")
    }
}

/// Header wiring for the album grid: "N SELECTED" with ALL / NONE while selecting (nothing otherwise).
struct LibrarySelectionHeader: View {
    let library: GallerySelectionModel
    let album: AlbumModel
    let rawOnly: Bool

    var body: some View {
        if library.isSelecting {
            LibrarySelectionStatus(
                count: library.selection.count, canSelectAll: !rawOnly,
                onAll: { library.selectAll(album.result) }, onNone: { library.selectNone() })
        }
    }
}

/// SELECT / DONE wired to the model.
struct LibrarySelectControl: View {
    let library: GallerySelectionModel

    var body: some View {
        LibrarySelectToggle(isSelecting: library.isSelecting) {
            if library.isSelecting { library.finishSelecting() } else { library.beginSelecting() }
        }
    }
}

/// A square lichen check badge, top-trailing on a selected cell.
struct LibraryCheckBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(T.ink)
            .frame(width: 18, height: 18)
            .background(T.lichen)
            .accessibilityHidden(true)
    }
}

/// The favorite chip on a cell: a small filled heart on the photo veil, like the RAW / EDITED badges.
struct LibraryFavoriteChip: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 9))
            .foregroundStyle(T.onPhoto)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(T.onPhotoVeil)
            .accessibilityLabel("Favorite")
    }
}

/// The selected state laid over a cell: a 1.5 pt lichen inset border and the check badge.
struct LibrarySelectedOverlay: View {
    var body: some View {
        Rectangle().strokeBorder(T.lichen, lineWidth: 1.5)
            .overlay(alignment: .topTrailing) { LibraryCheckBadge().padding(4) }
            .allowsHitTesting(false)
    }
}

/// A mono line at the bottom for errors and notes, and the PREPARING overlay.
struct LibraryNoticeLine: View {
    let text: String
    var body: some View {
        Text(text).ffLabel(size: 10, color: T.paper).lineLimit(2).multilineTextAlignment(.center)
            .padding(.horizontal, T.cells(2)).padding(.vertical, T.cells(1))
            .background(T.inkSoft)
            .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
            .accessibilityIdentifier("library.notice")
    }
}
