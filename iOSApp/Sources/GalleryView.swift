import MiraCore
import MiraUI
import Photos
import PhotosUI
import SwiftUI

/// Where the user is inside the album tree; the NavigationStack path is the preserved "place".
enum AlbumRoute: Hashable {
    case folder(id: String, title: String)
    case album(id: String, title: String)
}

struct GalleryView: View {
    @Bindable var editor: EditorViewModel
    @State private var gallery = GalleryModel()
    @State private var path: [AlbumRoute] = []
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            NavigationStack(path: $path) {
                root
                    .navigationDestination(for: AlbumRoute.self) { route in
                        switch route {
                        case let .folder(id, title): FolderListView(gallery: gallery, folderID: id, title: title)
                        case let .album(id, title): AlbumGridView(gallery: gallery, editor: editor, nodeID: id, title: title)
                        }
                    }
            }
            switch gallery.openPhase {
            case .idle:
                EmptyView()
            case .opening(let detail):
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: FieldFramesTheme.rows(1)) {
                    Text("OPENING").ffLabel(size: 11, color: FieldFramesTheme.paper)
                    if let detail {
                        Text(detail).ffLabel(size: 11, color: FieldFramesTheme.paper)
                    }
                }
            case .failed(_, let message):
                Color.black.opacity(0.45).ignoresSafeArea()
                FFOpenFailureCard(message: message,
                                  onRetry: { Task { await gallery.retry(in: editor) } },
                                  onBack: { gallery.dismissFailure() })
                    .padding(FieldFramesTheme.cells(2))
            }
        }
        .task { await gallery.start() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await editor.pick(item); pickerItem = nil }
        }
    }

    private var root: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                FFHairline()
                content
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: FieldFramesTheme.cells(1)) {
            Text("Mira").font(FieldFramesTheme.display(22, weight: .regular))
            Text(gallery.hasAccess ? (gallery.libraryCount.map { "\($0) \($0 == 1 ? "PHOTO" : "PHOTOS")" } ?? "") : editor.status)
                .ffLabel(size: 9, color: FieldFramesTheme.paperDim).lineLimit(1)
            Spacer(minLength: 0)
            if gallery.status == .limited {
                Button { gallery.presentLimitedPicker() } label: {
                    Text("ADD MORE").ffLabel(size: 11, color: FieldFramesTheme.lichen).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                ImportLabel().frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .frame(height: 44)
    }

    @ViewBuilder private var content: some View {
        switch gallery.status {
        case .authorized, .limited:
            if !gallery.loadedSections {
                Color.clear.frame(maxHeight: .infinity)
            } else if gallery.sections.isEmpty {
                FFEmptyState(title: "No photos", subtitle: gallery.status == .limited
                             ? "NO PHOTOS IN YOUR SELECTION" : "YOUR LIBRARY HAS NO PICTURES")
            } else {
                AlbumListView(gallery: gallery, sections: gallery.sections)
            }
        case .denied, .restricted:
            FFEmptyState(title: "Photos access is off",
                         subtitle: gallery.status == .restricted ? "PHOTO ACCESS IS RESTRICTED ON THIS DEVICE"
                         : "ALLOW ACCESS IN SETTINGS TO BROWSE YOUR LIBRARY",
                         buttonTitle: gallery.status == .restricted ? nil : "OPEN SETTINGS") {
                GalleryModel.openSettings()
            }
        default:
            Color.clear.frame(maxHeight: .infinity)
        }
    }
}

/// Sections in Photos' order (LIBRARY, ALBUMS, SHARED ALBUMS, MEDIA TYPES, UTILITIES) from `SidebarModel`.
/// LIBRARY leads with a wide hero cover; ALBUMS / SHARED ALBUMS are 2-column cover grids;
/// MEDIA TYPES / UTILITIES (many, mostly small) are compact rows with a thumbnail.
private struct AlbumListView: View {
    let gallery: GalleryModel
    let sections: [SidebarSection]
    private let margin = FieldFramesTheme.cells(2)
    private let gap: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let side = floor((geo.size.width - margin * 2 - gap) / 2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        let nodes = SidebarModel.visible(section.nodes)
                        switch section.id {
                        case "library": library(nodes, side: side, width: geo.size.width - margin * 2)
                        case "media", "utilities": rows(nodes)
                        default: grid(nodes, side: side)
                        }
                    }
                }
                .padding(.bottom, FieldFramesTheme.rows(3))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: FieldFramesTheme.cells(1)) {
            Text(title.uppercased()).ffLabel(size: 10, color: FieldFramesTheme.paperMid)
            FFHairline()
        }
        .padding(.horizontal, margin)
        .padding(.top, FieldFramesTheme.rows(2)).padding(.bottom, FieldFramesTheme.cells(1.5))
    }

    private func library(_ nodes: [SidebarNode], side: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            if let hero = nodes.first {
                NavigationLink(value: AlbumRoute.album(id: hero.id, title: hero.title)) {
                    CoverTile(gallery: gallery, node: hero, size: CGSize(width: width, height: floor(width * 0.62)),
                              titleSize: 26)
                }
                .buttonStyle(.plain)
            }
            if nodes.count > 1 { grid(Array(nodes.dropFirst()), side: side, padded: false) }
        }
        .padding(.horizontal, margin)
    }

    private func grid(_ nodes: [SidebarNode], side: CGFloat, padded: Bool = true) -> some View {
        LazyVGrid(columns: [GridItem(.fixed(side), spacing: gap, alignment: .top),
                            GridItem(.fixed(side), spacing: 0, alignment: .top)],
                  alignment: .leading, spacing: gap + 4) {
            ForEach(nodes) { node in
                NavigationLink(value: route(node)) {
                    CoverTile(gallery: gallery, node: node, size: CGSize(width: side, height: side), titleSize: 17)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, padded ? margin : 0)
    }

    private func rows(_ nodes: [SidebarNode]) -> some View {
        VStack(spacing: 0) {
            ForEach(nodes) { node in
                NodeRow(gallery: gallery, node: node)
                FFHairline().padding(.leading, margin)
            }
        }
    }
}

private func route(_ node: SidebarNode) -> AlbumRoute {
    node.isFolder ? .folder(id: node.id, title: node.title) : .album(id: node.id, title: node.title)
}

/// The id whose pictures best represent a node: itself for an album, the first non-empty child for a folder.
private func coverNodeID(_ node: SidebarNode) -> String? {
    guard node.isFolder else { return node.id }
    for child in SidebarModel.visible(node.children) { if let id = coverNodeID(child) { return id } }
    return nil
}

private func subtitle(_ node: SidebarNode) -> String {
    if node.isFolder {
        let n = SidebarModel.visible(node.children).count
        return "\(n) \(n == 1 ? "ITEM" : "ITEMS")"
    }
    return node.count.map { "\($0)" } ?? ""
}

/// Square (or wide) cover with a 1pt hairline, a Cormorant title and a mono count beneath.
private struct CoverTile: View {
    let gallery: GalleryModel
    let node: SidebarNode
    let size: CGSize
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(gallery: gallery, nodeID: coverNodeID(node), size: size)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topTrailing) {
                    if node.isFolder {
                        Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FieldFramesTheme.paper)
                            .padding(6).background(Color.black.opacity(0.55)).padding(6)
                    }
                }
                .overlay(Rectangle().strokeBorder(FieldFramesTheme.hair, lineWidth: 1))
            Text(node.title).font(FieldFramesTheme.display(titleSize, weight: .regular)).lineLimit(1)
            Text(subtitle(node)).ffLabel(size: 9, color: FieldFramesTheme.paperDim)
        }
        .frame(width: size.width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Lazy cover thumbnail: finds the cover asset off the main actor, then loads it through the shared
/// caching manager at size x display scale. Cancels its request when scrolled away.
private struct CoverImage: View {
    let gallery: GalleryModel
    let nodeID: String?
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color(white: 0.09)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else if nodeID == nil {
                    Image(systemName: "photo").font(.system(size: 18, weight: .light))
                        .foregroundStyle(FieldFramesTheme.paperDim.opacity(0.5))
                }
            }
            .clipped()
            .task(id: "\(nodeID ?? "-")|\(gallery.coverToken(for: nodeID))|\(Int(size.width))") { await load() }
            .onDisappear {
                if let id = requestID { gallery.covers.manager.cancelImageRequest(id) }
                requestID = nil
            }
    }

    private func load() async {
        guard let nodeID else { image = nil; return }
        let store = gallery.covers
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        let key = store.key(nodeID, pixels)
        let hit = store.image(for: key)
        if let hit { image = hit }
        let found = await Task.detached(priority: .userInitiated) { GalleryKit.coverAsset(nodeID: nodeID) }.value
        guard !Task.isCancelled else { return }
        guard let found else {
            // The album is empty or gone: drop a cover that no longer exists.
            if hit != nil { store.remove(nodeID: nodeID); image = nil }
            return
        }
        // A cached cover is shown at once, then kept only if it still is this node's cover asset.
        if hit != nil, store.assetID(for: key) == found.value.localIdentifier { return }
        ThumbnailMetrics.shared.recordRequest()
        let assetID = found.value.localIdentifier
        requestID = GalleryKit.requestThumbnail(
            manager: store.manager, asset: found, size: pixels, options: Unchecked(value: store.options)
        ) { box, _ in
            MainActor.assumeIsolated {
                guard let img = box.value else { return }
                image = img
                store.store(img, for: key, nodeID: nodeID, assetID: assetID)
            }
        }
    }
}

/// Compact row: small cover, title, mono count, chevron.
private struct NodeRow: View {
    let gallery: GalleryModel
    let node: SidebarNode

    var body: some View {
        NavigationLink(value: route(node)) {
            HStack(spacing: FieldFramesTheme.cells(1.5)) {
                CoverImage(gallery: gallery, nodeID: coverNodeID(node), size: CGSize(width: 52, height: 52))
                    .frame(width: 52, height: 52)
                    .overlay(Rectangle().strokeBorder(FieldFramesTheme.hair, lineWidth: 1))
                Text(node.title).font(FieldFramesTheme.display(18, weight: .regular)).lineLimit(1)
                Spacer(minLength: 0)
                Text(subtitle(node)).ffLabel(size: 10, color: FieldFramesTheme.paperDim)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FieldFramesTheme.paperDim)
            }
            .padding(.horizontal, FieldFramesTheme.cells(2))
            .padding(.vertical, 6)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A folder's children as a cover grid, in Photos' manual order (never re-sorted).
private struct FolderListView: View {
    let gallery: GalleryModel
    let folderID: String
    let title: String

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            let children = SidebarModel.visible(SidebarModel.node(withID: folderID, in: gallery.sections)?.children ?? [])
            if children.isEmpty {
                FFEmptyState(title: "Empty folder", subtitle: "NO ALBUMS IN THIS FOLDER")
            } else {
                GeometryReader { geo in
                    let margin = FieldFramesTheme.cells(2), gap: CGFloat = 14
                    let side = floor((geo.size.width - margin * 2 - gap) / 2)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.fixed(side), spacing: gap, alignment: .top),
                                            GridItem(.fixed(side), spacing: 0, alignment: .top)],
                                  alignment: .leading, spacing: gap + 4) {
                            ForEach(children) { node in
                                NavigationLink(value: route(node)) {
                                    CoverTile(gallery: gallery, node: node, size: CGSize(width: side, height: side),
                                              titleSize: 17)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, margin).padding(.vertical, gap)
                    }
                }
            }
        }
        .ffNavigationTitle(title)
    }
}

struct AlbumGridView: View {
    let gallery: GalleryModel
    @Bindable var editor: EditorViewModel
    let title: String
    @State private var album: AlbumModel
    /// Persisted ALL / RAW choice, shared by every album.
    @AppStorage("gallery.rawOnly") private var rawOnly = false
    @Environment(\.displayScale) private var displayScale

    private let columns = 3
    private let gutter: CGFloat = 1

    init(gallery: GalleryModel, editor: EditorViewModel, nodeID: String, title: String) {
        self.gallery = gallery
        self.editor = editor
        self.title = title
        _album = State(initialValue: AlbumModel(nodeID: nodeID))
    }

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("\(album.count) \(rawOnly ? "RAW" : (album.count == 1 ? "PHOTO" : "PHOTOS"))").ffLabel(size: 9, color: FieldFramesTheme.paperDim)
                    if let progress = album.scanProgress {
                        Text("SCANNING \(progress.done.formatted()) / \(progress.total.formatted())")
                            .ffLabel(size: 9, color: FieldFramesTheme.lichen).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    FFTabBar([(value: false, title: "ALL"),
                              (value: true, title: album.rawCount.map { "RAW \($0.formatted())" } ?? "RAW")],
                             selection: $rawOnly,
                             spacing: FieldFramesTheme.cells(2))
                        .accessibilityLabel("Show all photos or RAW only")
                    if gallery.status == .limited {
                        Button { gallery.presentLimitedPicker() } label: {
                            Text("ADD MORE").ffLabel(size: 11, color: FieldFramesTheme.lichen).frame(minHeight: 44)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, FieldFramesTheme.cells(2))
                .frame(height: 32)
                FFHairline()
                if !album.loaded {
                    Color.clear.frame(maxHeight: .infinity)
                } else if album.count == 0 {
                    if rawOnly {
                        FFEmptyState(title: "No RAW photos", subtitle: album.scanning
                                     ? "SCANNING FOR RAW PHOTOS" : "THIS ALBUM HAS NO RAW PICTURES")
                    } else {
                        FFEmptyState(title: "No photos", subtitle: gallery.status == .limited
                                     ? "NO PHOTOS IN YOUR SELECTION" : "THIS ALBUM HAS NO PICTURES")
                    }
                } else { grid }
            }
        }
        .ffNavigationTitle(title)
        // Loads once. Later library changes arrive through `album.apply`, not by refetching the album.
        .task { if !album.loaded { await album.reload(rawOnly: rawOnly, gallery: gallery) } }
        .onChange(of: rawOnly) { _, on in album.setRawOnly(on) }
        .onDisappear { album.cancelWork(); album.stopCaching() }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - gutter * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gutter), count: columns),
                          spacing: gutter) {
                    ForEach(0..<album.count, id: \.self) { index in
                        if let asset = album.asset(at: index) {
                            GalleryCell(album: album, asset: asset, index: index)
                                .aspectRatio(1, contentMode: .fit)
                                .onTapGesture { Task { await gallery.open(asset, in: editor) } }
                        }
                    }
                }
            }
            .onAppear { album.setThumbSize(CGSize(width: cell * displayScale, height: cell * displayScale)) }
            .onChange(of: cell) { _, c in album.setThumbSize(CGSize(width: c * displayScale, height: c * displayScale)) }
        }
    }
}

private extension View {
    /// Inline Cormorant title over a transparent bar; the back control keeps the lichen tint.
    func ffNavigationTitle(_ title: String) -> some View {
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(FieldFramesTheme.display(20, weight: .regular)).lineLimit(1)
                }
            }
    }
}

private struct GalleryCell: View {
    let album: AlbumModel
    let asset: PHAsset
    let index: Int
    @State private var loader = ThumbnailCellLoader<UIImage, PHAsset>()
    @State private var badges: (raw: Bool, edited: Bool) = (false, false)
    @State private var badgeKey: GridThumbnailKey?

    var body: some View {
        let key = album.thumbnailKey(for: asset)
        Color(white: 0.1)
            .overlay {
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if badges.raw { badge("RAW") }
                    if badges.edited { badge("EDITED") }
                }
                .padding(4)
            }
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                album.updateCaching(around: index)
                refresh(key)
            }
            .onChange(of: key) { _, new in refresh(new) }
            .onDisappear { loader.cancel() }
    }

    private func badge(_ text: String) -> some View {
        Text(text).ffLabel(size: 8, color: FieldFramesTheme.paper)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.6))
    }

    /// Memory cache first; PhotoKit only when this asset's thumbnail at this size/version is not cached.
    private func refresh(_ key: GridThumbnailKey) {
        loader.update(key, asset: asset, pipeline: album.thumbnails)
        guard badgeKey?.id != key.id || badgeKey?.version != key.version else { return }
        badgeKey = key
        let boxed = Unchecked(value: asset)
        Task.detached(priority: .utility) {
            let found = GalleryKit.badges(of: boxed)
            await MainActor.run { badges = found }
        }
    }
}

struct ImportLabel: View {
    var body: some View { Text("IMPORT").ffLabel(size: 11, color: FieldFramesTheme.paperDim) }
}
