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
            if gallery.isOpening {
                Color.black.opacity(0.45).ignoresSafeArea()
                Text("OPENING").ffLabel(size: 11, color: FieldFramesTheme.paper)
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
            Text(gallery.hasAccess ? (gallery.libraryCount.map { "\($0) PHOTOS" } ?? "") : editor.status)
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
                AlbumListView(sections: gallery.sections)
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
private struct AlbumListView: View {
    let sections: [SidebarSection]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Text(section.title.uppercased()).ffLabel(size: 9, color: FieldFramesTheme.paperDim)
                        .padding(.horizontal, FieldFramesTheme.cells(2))
                        .padding(.top, FieldFramesTheme.cells(3)).padding(.bottom, FieldFramesTheme.cells(1))
                    FFHairline()
                    ForEach(SidebarModel.visible(section.nodes)) { node in
                        NodeRow(node: node)
                        FFHairline()
                    }
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: SidebarNode

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: FieldFramesTheme.cells(1)) {
                Text(node.title).font(.system(size: 16)).lineLimit(1)
                Spacer(minLength: 0)
                if let count = node.count, !node.isFolder {
                    Text("\(count)").ffLabel(size: 10, color: FieldFramesTheme.paperDim)
                }
                if node.isFolder {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FieldFramesTheme.paperDim)
                }
            }
            .padding(.horizontal, FieldFramesTheme.cells(2))
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var route: AlbumRoute {
        node.isFolder ? .folder(id: node.id, title: node.title) : .album(id: node.id, title: node.title)
    }
}

/// A folder's children, in Photos' manual order (never re-sorted).
private struct FolderListView: View {
    let gallery: GalleryModel
    let folderID: String
    let title: String

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            let children = SidebarModel.node(withID: folderID, in: gallery.sections)?.children ?? []
            if children.isEmpty {
                FFEmptyState(title: "Empty folder", subtitle: "NO ALBUMS IN THIS FOLDER")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        FFHairline()
                        ForEach(SidebarModel.visible(children)) { node in
                            NodeRow(node: node)
                            FFHairline()
                        }
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
                    Text("\(album.count) PHOTOS").ffLabel(size: 9, color: FieldFramesTheme.paperDim)
                    Spacer(minLength: 0)
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
                    FFEmptyState(title: "No photos", subtitle: gallery.status == .limited
                                 ? "NO PHOTOS IN YOUR SELECTION" : "THIS ALBUM HAS NO PICTURES")
                } else { grid }
            }
        }
        .ffNavigationTitle(title)
        .task(id: gallery.revision) { await album.reload() }
        .onDisappear { album.stopCaching() }
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
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var badges: (raw: Bool, edited: Bool) = (false, false)

    var body: some View {
        Color(white: 0.1)
            .overlay {
                if let image {
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
                guard image == nil else { return }
                request()
                let boxed = Unchecked(value: asset)
                Task.detached(priority: .utility) {
                    let found = GalleryKit.badges(of: boxed)
                    await MainActor.run { badges = found }
                }
            }
            .onDisappear {
                if let id = requestID { album.caching.cancelImageRequest(id) }
                requestID = nil
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text).ffLabel(size: 8, color: FieldFramesTheme.paper)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.6))
    }

    private func request() {
        let size = album.thumbSize == .zero ? CGSize(width: 300, height: 300) : album.thumbSize
        requestID = GalleryKit.requestThumbnail(
            manager: album.caching, asset: Unchecked(value: asset), size: size,
            options: Unchecked(value: album.thumbOptions)
        ) { box in
            MainActor.assumeIsolated { if let img = box.value { image = img } }
        }
    }
}

struct ImportLabel: View {
    var body: some View { Text("IMPORT").ffLabel(size: 11, color: FieldFramesTheme.paperDim) }
}
