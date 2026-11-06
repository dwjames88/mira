import AppKit
import MiraCore
import MiraUI
import Photos
import SwiftUI

private typealias T = FieldFramesTheme

/// The Library mode: sidebar of sources plus a grid of the current one.
struct LibraryView: View {
    let state: AppState
    /// False while the editor covers the library. The view stays mounted (scroll position and cell
    /// state survive), so this only decides whether the grid takes keyboard focus back.
    var isActive = true
    var store: LibraryStore { state.store }

    var body: some View {
        Group {
            switch store.authorization {
            case .authorized, .limited:
                HStack(spacing: 0) {
                    LibrarySidebar(store: store)
                        .frame(width: T.cells(30))
                    FFHairline(.vertical)
                    LibraryGridPane(state: state, isActive: isActive)
                }
            case .notDetermined:
                VStack { Text("Waiting for Photos access").ffLabel(size: 11) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                FFEmptyState(
                    title: "Photos is off limits",
                    subtitle: "Mira has no access to your library",
                    buttonTitle: "Open Privacy Settings",
                    note: "Allow Mira under Privacy & Security \u{25B8} Photos, then come back. You can still open files from disk.",
                    action: openPrivacySettings)
            default:
                FFEmptyState(
                    title: "Photos is restricted",
                    subtitle: "This Mac does not allow library access",
                    note: "You can still open files from disk with Open.")
            }
        }
        .task { await store.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshAuthorization()
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Sidebar

private struct LibrarySidebar: View {
    let store: LibraryStore
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: store.selectedNodeID) { _, id in
                    // Keep the selected row on screen when the arrow keys move past the edge.
                    proxy.scrollTo(id, anchor: nil)
                }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.sections.enumerated()), id: \.element.id) { offset, section in
                    if offset > 0 {
                        FFHairline()
                            .padding(.horizontal, T.cells(2))
                            .padding(.top, T.rows(1))
                    }
                    let collapsed = store.isSectionCollapsed(section.id)
                    SectionHeader(title: section.title, collapsed: collapsed,
                                  onAdd: section.id == "albums" && store.canManageAlbums && store.authorization == .authorized
                                      ? { store.beginNewAlbum() } : nil) {
                        focused = true
                        withAnimation(.easeOut(duration: 0.12)) { store.toggleSection(section.id) }
                    }
                    if !collapsed {
                        let hasFolders = section.nodes.contains(where: \.isFolder)
                        ForEach(SidebarModel.visibleRows(in: section, expanded: store.expanded), id: \.node.id) { row in
                            SidebarRow(node: row.node, depth: row.depth, reserveChevron: hasFolders,
                                       expanded: store.isExpanded(row.node.id),
                                       selected: store.selectedNodeID == row.node.id) {
                                focused = true
                                if row.node.isFolder { store.toggleExpanded(row.node.id) } else { store.select(row.node) }
                            }
                            .id(row.node.id)
                            .sidebarLibraryActions(store: store, node: row.node)
                        }
                    }
                }
            }
            .padding(.vertical, T.rows(1))
        }
        .background(T.inkSoft.opacity(0.5))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
    }
}

/// A collapsible section title: mono uppercase label with a small chevron that turns when open.
private struct SectionHeader: View {
    let title: String
    let collapsed: Bool
    /// A small `+` at the trailing edge (the ALBUMS section: new album); nil for none.
    var onAdd: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: T.cells(1)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(T.paperDim)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: T.cells(1.5))
                    Text(title).ffLabel()
                    Spacer(minLength: 0)
                }
                .padding(.leading, T.cells(2))
                .padding(.trailing, onAdd == nil ? T.cells(2) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(title), \(collapsed ? "collapsed" : "expanded")")
            if let onAdd {
                AddButton(action: onAdd)
            }
        }
        .padding(.top, T.rows(1))
        .padding(.bottom, T.rows(0.5))
    }

    private struct AddButton: View {
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text("+")
                    .font(T.mono(13, weight: .medium))
                    .foregroundStyle(hovering ? T.paper : T.paperDim)
                    .frame(width: T.cells(3), height: T.rows(1.25))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.trailing, T.cells(1))
            .help("New album \u{21E7}\u{2318}N")
            .accessibilityLabel("New album")
        }
    }
}

private struct SidebarRow: View {
    let node: SidebarNode
    let depth: Int
    let reserveChevron: Bool
    let expanded: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.cells(1)) {
                if reserveChevron {
                    Group {
                        if node.isFolder {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(T.paperDim)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .frame(width: T.cells(1.5))
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(T.paperDim)
                        .frame(width: T.cells(2))
                }
                Text(node.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? T.paper : T.paperMid)
                    .lineLimit(1)
                Spacer(minLength: T.cells(1))
                if let count = node.count { Text("\(count)").ffLabel(size: 10) }
            }
            .padding(.leading, T.cells(2) + CGFloat(depth) * T.cells(2))
            .padding(.trailing, T.cells(2))
            .frame(height: T.rows(2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if selected { Rectangle().fill(T.lichen).frame(width: 2) }
            }
            .background(selected ? T.hair : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(node.isFolder ? "\(node.title), folder, \(expanded ? "expanded" : "collapsed")" : node.title)
    }

    private var symbol: String? {
        switch node.kind {
        case .folder: "folder"
        case .album: "rectangle.stack"
        default: nil
        }
    }
}

// MARK: Grid

private struct LibraryGridPane: View {
    let state: AppState
    let isActive: Bool
    var store: LibraryStore { state.store }
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var displayScale

    private let minCell: CGFloat = 150
    private let gap = FieldFramesTheme.cellW

    var body: some View {
        HStack(spacing: 0) {
            gridColumn
            if store.inspectorOpen {
                LibraryInspector(store: store)
                    .transition(.identity)
            }
        }
    }

    private var gridColumn: some View {
        VStack(spacing: 0) {
            header
            FFHairline()
            if store.count == 0 {
                VStack(spacing: T.rows(1)) {
                    if store.filterPending {
                        Text("Filtering").ffLabel(size: 11)
                    } else if store.filter.isActive {
                        Text("No photos match the filter").ffLabel(size: 11)
                        if let line = store.indexProgress.line, store.filter.needsMetadata {
                            Text("\(line) \u{00B7} only indexed photos can match").ffLabel(size: 10, color: T.lichen)
                        }
                    } else {
                        Text("Nothing here").ffLabel(size: 11)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let columns = max(1, Int((geo.size.width - gap * 2 + gap) / (minCell + gap)))
                    // Cell side in points: the width inside the padding, minus the gaps, over the columns.
                    let side = (geo.size.width - gap * 4 - gap * CGFloat(columns - 1)) / CGFloat(columns)
                    grid(columns: columns)
                        .onAppear { store.setCellSize(points: side, scale: displayScale) }
                        .onChange(of: side) { _, new in store.setCellSize(points: new, scale: displayScale) }
                }
            }
            if let note = store.actionNote ?? state.libraryNote ?? state.presetTransfer.notice {
                FFHairline()
                Text(note).ffLabel(size: 10)
                    .padding(.horizontal, T.cells(2))
                    .frame(maxWidth: .infinity, minHeight: T.rows(2), alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: T.cells(2)) {
            VStack(alignment: .leading, spacing: 0) {
                if store.breadcrumb.count > 1 {
                    Text(store.breadcrumb.joined(separator: " \u{203A} ")).ffLabel(size: 10)
                        .lineLimit(1)
                }
                Text(store.selectedNode?.title ?? "Photos")
                    .font(T.display(30, weight: .medium))
                    .foregroundStyle(T.paper)
            }
            Text(store.filter.needsAssetPass ? "\(store.count) OF \(store.collectionCount) PHOTOS" : "\(store.count) PHOTOS").ffLabel(size: 10)
            if store.isReadOnlySelection {
                Text("READ ONLY").ffLabel(size: 10, color: T.lichen)
            }
            if store.authorization == .limited {
                Text("LIMITED ACCESS").ffLabel(size: 10, color: T.lichen)
            }
            if store.selection.count > 1 {
                Text("\(store.selection.count) SELECTED").ffLabel(size: 10, color: T.lichen)
            }
            Spacer()
            if !store.selection.isEmpty { LibraryHeaderActions(store: store) }
            RawQuickToggle(store: store)
            FilterButton(store: store)
        }
        .padding(.horizontal, T.cells(2))
        .padding(.vertical, T.rows(0.5))
    }

    private func grid(columns: Int) -> some View {
        let items = Array(repeating: GridItem(.flexible(), spacing: gap), count: columns)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: items, spacing: gap) {
                    ForEach(0..<store.count, id: \.self) { index in
                        AssetCell(state: state, index: index)
                            .id(index)
                            .onTapGesture(count: 2) {
                                store.handleClick(index: index, modifiers: [])
                                open(index)
                            }
                            .onTapGesture {
                                store.handleClick(index: index, modifiers: Self.currentModifiers())
                                focused = true
                            }
                    }
                }
                .padding(gap * 2)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.return) {
                guard let i = store.selectedIndex else { return .ignored }
                open(i)
                return .handled
            }
            .onKeyPress(.leftArrow) { move(-1, proxy) }
            .onKeyPress(.rightArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-columns, proxy) }
            .onKeyPress(.downArrow) { move(columns, proxy) }
            .onKeyPress(.escape) {
                guard !store.selection.isEmpty else { return .ignored }
                store.clearSelection()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
                guard press.modifiers == .command else { return .ignored }
                store.selectAll()
                return .handled
            }
            .onAppear { focused = isActive }
            .onChange(of: isActive) { _, active in focused = active }
        }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard store.count > 0 else { return .ignored }
        let next = min(max(0, (store.selectedIndex ?? (delta > 0 ? -1 : store.count)) + delta), store.count - 1)
        store.moveCursor(to: next, extend: NSEvent.modifierFlags.contains(.shift))
        proxy.scrollTo(next)
        return .handled
    }

    /// The command and shift keys held right now (a click handler runs while the click's modifiers are still down).
    private static func currentModifiers() -> LibraryClickModifiers {
        let flags = NSEvent.modifierFlags
        var result: LibraryClickModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func open(_ index: Int) {
        guard let asset = store.asset(at: index) else { return }
        state.openAsset(asset, readOnly: store.isReadOnlySelection)
    }
}

/// A square thumbnail. Reads the memory cache first and asks PhotoKit only on a miss; it refreshes
/// when its asset changes or PhotoKit reports that asset edited, never because something else did.
private struct AssetCell: View {
    let state: AppState
    let index: Int
    var store: LibraryStore { state.store }
    @State private var loader = ThumbnailCellLoader<NSImage, PHAsset>()
    @State private var isRAW = false

    /// `Date.formatted` builds a formatter on every call; one shared formatter keeps cell bodies cheap.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        let asset = store.asset(at: index)
        let key = asset.map { store.thumbnailKey(for: $0) }
        let id = asset?.localIdentifier
        let selected = id.map { store.selection.contains($0) } ?? false
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    T.inkSoft
                    if let image = loader.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if isRAW { badge("RAW") }
                    if asset?.hasAdjustments == true { badge("EDITED") }
                }
                .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                if asset?.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(T.onPhoto)
                        .padding(3)
                        .background(T.onPhotoVeil)
                        .padding(4)
                        .accessibilityLabel("Favorite")
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected, store.selection.count > 1 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(T.ink)
                        .frame(width: 14, height: 14)
                        .background(T.lichen)
                        .padding(4)
                }
            }
            .overlay {
                if selected { Rectangle().strokeBorder(T.lichen, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .libraryDraggable(store: store, id: id)
            .contextMenu {
                if let id { LibraryContextMenu(state: state, index: index, id: id) }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(asset?.creationDate.map { "Photo, \(Self.dateFormatter.string(from: $0))" } ?? "Photo")
            .onAppear {
                store.prefetch(around: index)
                load(asset)
            }
            .onDisappear { loader.cancel() }
            .onChange(of: key) { _, _ in load(store.asset(at: index)) }
            .task(id: asset?.localIdentifier) {
                guard let asset else { return }
                if let cached = store.cachedRAW(asset) { isRAW = cached; return }
                isRAW = await store.isRAW(asset)
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(T.mono(9, weight: .medium))
            .tracking(9 * T.labelTracking)
            .foregroundStyle(T.onPhoto)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(T.onPhotoVeil)
    }

    private func load(_ asset: PHAsset?) {
        loader.update(asset.map { store.thumbnailKey(for: $0) }, asset: asset, pipeline: store.thumbnails)
    }
}
