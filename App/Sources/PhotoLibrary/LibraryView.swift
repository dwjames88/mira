import AppKit
import MiraCore
import MiraUI
import Photos
import SwiftUI

private typealias T = FieldFramesTheme

/// The Library mode: sidebar of sources plus a grid of the current one.
struct LibraryView: View {
    let state: AppState
    var store: LibraryStore { state.store }

    var body: some View {
        Group {
            switch store.authorization {
            case .authorized, .limited:
                HStack(spacing: 0) {
                    LibrarySidebar(store: store)
                        .frame(width: T.cells(30))
                    FFHairline(.vertical)
                    LibraryGridPane(state: state)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.sections.enumerated()), id: \.element.id) { offset, section in
                    if offset > 0 {
                        FFHairline()
                            .padding(.horizontal, T.cells(2))
                            .padding(.top, T.rows(1))
                    }
                    Text(section.title).ffLabel()
                        .padding(.horizontal, T.cells(2))
                        .padding(.top, T.rows(1))
                        .padding(.bottom, T.rows(0.5))
                        .accessibilityAddTraits(.isHeader)
                    let hasFolders = section.nodes.contains(where: \.isFolder)
                    ForEach(SidebarModel.visibleRows(in: section, expanded: store.expanded), id: \.node.id) { row in
                        SidebarRow(node: row.node, depth: row.depth, reserveChevron: hasFolders, monoTitle: section.id == "stars",
                                   expanded: store.isExpanded(row.node.id),
                                   selected: store.selectedNodeID == row.node.id) {
                            focused = true
                            if row.node.isFolder { store.toggleExpanded(row.node.id) } else { store.select(row.node) }
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

private struct SidebarRow: View {
    let node: SidebarNode
    let depth: Int
    let reserveChevron: Bool
    let monoTitle: Bool
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
                    .font(monoTitle ? T.mono(12) : .system(size: 13))
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
    var store: LibraryStore { state.store }
    @FocusState private var focused: Bool

    private let minCell: CGFloat = 150
    private let gap = FieldFramesTheme.cellW

    var body: some View {
        VStack(spacing: 0) {
            header
            FFHairline()
            if store.count == 0 {
                VStack { Text("Nothing here").ffLabel(size: 11) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let columns = max(1, Int((geo.size.width - gap * 2 + gap) / (minCell + gap)))
                    grid(columns: columns)
                }
            }
            if let note = state.libraryNote {
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
            Text("\(store.count) PHOTOS").ffLabel(size: 10)
            if store.isReadOnlySelection {
                Text("READ ONLY").ffLabel(size: 10, color: T.lichen)
            }
            if store.authorization == .limited {
                Text("LIMITED ACCESS").ffLabel(size: 10, color: T.lichen)
            }
            Spacer()
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
                        AssetCell(store: store, index: index, selected: store.selectedIndex == index)
                            .id(index)
                            .onTapGesture(count: 2) {
                                store.selectedIndex = index
                                open(index)
                            }
                            .onTapGesture {
                                store.selectedIndex = index
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
            .onAppear { focused = true }
        }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard store.count > 0 else { return .ignored }
        let next = min(max(0, (store.selectedIndex ?? (delta > 0 ? -1 : store.count)) + delta), store.count - 1)
        store.selectedIndex = next
        proxy.scrollTo(next)
        return .handled
    }

    private func open(_ index: Int) {
        guard let asset = store.asset(at: index) else { return }
        state.openAsset(asset, readOnly: store.isReadOnlySelection)
    }
}

/// A square thumbnail. Loads when it appears, cancels when it disappears.
private struct AssetCell: View {
    let store: LibraryStore
    let index: Int
    let selected: Bool
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?
    @State private var isRAW = false

    var body: some View {
        // Reading the revision re-evaluates the cell after library changes.
        let _ = store.revision
        let asset = store.asset(at: index)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    T.inkSoft
                    if let image {
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
            .overlay {
                if selected { Rectangle().strokeBorder(T.lichen, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(asset?.creationDate.map { "Photo, \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Photo")
            .onAppear {
                store.prefetch(around: index)
                load(asset)
            }
            .onDisappear { cancel() }
            .onChange(of: store.revision) { _, _ in
                cancel()
                load(store.asset(at: index))
            }
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
        guard let asset else { return }
        cancel()
        requestID = store.requestThumbnail(for: asset) { img in
            if let img { image = img }
        }
    }

    private func cancel() {
        if let requestID { store.cancelThumbnail(requestID) }
        requestID = nil
    }
}
