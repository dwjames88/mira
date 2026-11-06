import MiraCore
import MiraUI
import Photos
import SwiftUI

/// The DEVELOP card at the top of the library: count, hint and the newest queued photo's thumbnail.
/// Loads through the gallery's cover manager and cache; it requests only when the newest item changes,
/// never on appear (so coming back from the editor costs no request).
struct DevelopCard: View {
    let gallery: GalleryModel
    @State private var store = DevelopStore.shared
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    private let side: CGFloat = 64
    /// Only the queued photos the library scope shows count here and give the thumbnail.
    private var shown: [DevelopQueue.Entry] { gallery.developEntries(store.queue) }

    var body: some View {
        NavigationLink(value: AlbumRoute.develop) {
            HStack(spacing: FieldFramesTheme.cells(1.5)) {
                Color(white: 0.09)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                        else {
                            Image(systemName: "tray").font(.system(size: 18, weight: .light))
                                .foregroundStyle(FieldFramesTheme.paperDim.opacity(0.6))
                        }
                    }
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(Rectangle().strokeBorder(FieldFramesTheme.hair, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEVELOP \u{00B7} \(shown.count)").ffLabel(size: 12, color: FieldFramesTheme.lichen)
                    Text(shown.count == 0 ? "FRAMES FROM THE CAMERA LAND HERE" : "NEWEST FIRST \u{00B7} TAP TO DEVELOP")
                        .ffLabel(size: 9, color: FieldFramesTheme.paperDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FieldFramesTheme.paperDim)
            }
            .padding(FieldFramesTheme.cells(1))
            .overlay(Rectangle().strokeBorder(FieldFramesTheme.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .padding(.top, FieldFramesTheme.cells(1.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.developCard")
        .task(id: "\(gallery.scope.rawValue)|\(store.queue.ids.joined(separator: ","))") { await gallery.refreshDevelopScope(ids: store.queue.ids) }
        .task(id: "\(shown.first?.id ?? "-")") { await load() }
        .onDisappear {
            if let id = requestID { gallery.covers.manager.cancelImageRequest(id) }
            requestID = nil
        }
    }

    private func load() async {
        guard let assetID = shown.first?.id else { image = nil; return }
        let covers = gallery.covers
        let pixels = CGSize(width: side * displayScale, height: side * displayScale)
        let key = covers.key("develop", pixels)
        if let hit = covers.image(for: key), covers.assetID(for: key) == assetID { image = hit; return }
        let found = await Task.detached(priority: .userInitiated) {
            PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: DevelopStore.allSourcesOptions()).firstObject.map { Unchecked(value: $0) }
        }.value
        guard !Task.isCancelled, let found else { return }
        ThumbnailMetrics.shared.recordRequest()
        requestID = GalleryKit.requestThumbnail(
            manager: covers.manager, asset: found, size: pixels, options: Unchecked(value: covers.options)
        ) { box, _ in
            MainActor.assumeIsolated {
                guard let img = box.value else { return }
                image = img
                covers.store(img, for: key, nodeID: "develop", assetID: assetID)
            }
        }
    }
}

/// The queue as a grid, newest first. Items already edited with Mira carry a small lichen tick.
struct DevelopQueueView: View {
    let gallery: GalleryModel
    @Bindable var editor: EditorViewModel
    @State private var store = DevelopStore.shared
    @State private var assets: [PHAsset] = []
    @State private var edited: Set<String> = []
    @State private var loaded = false
    @State private var confirmClear = false
    /// Library actions and SELECT mode, as in an album grid (library-wide availability: no move or remove).
    @State private var library = GallerySelectionModel(nodeID: "all")
    @Environment(\.displayScale) private var displayScale

    private let columns = 3
    private let gutter: CGFloat = 1

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                actions
                FFHairline()
                if assets.isEmpty {
                    if loaded {
                        FFEmptyState(title: "Nothing to develop", subtitle: "FRAMES YOU SHOOT WITH THE CAMERA LAND HERE")
                    } else { Color.clear.frame(maxHeight: .infinity) }
                } else { grid }
            }
        }
        .ffNavigationTitle("Develop")
        .libraryChrome(library, album: nil, gallery: gallery)
        .accessibilityIdentifier("develop.queue")
        .task(id: "\(gallery.scope.rawValue)|\(store.queue.ids.joined(separator: ","))") { await reload() }
        .confirmationDialog("Clear the Develop queue?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clear() }
        } message: { Text("Photos stay in your library.") }
    }

    private var actions: some View {
        HStack(spacing: FieldFramesTheme.cells(2)) {
            if library.isSelecting {
                LibrarySelectionStatus(
                    count: library.selection.count, canSelectAll: true,
                    onAll: { library.selection.selectAll(assets.map(\.localIdentifier)); library.refreshFlags() },
                    onNone: { library.selectNone() })
            } else {
                Text("\(assets.count) QUEUED").ffLabel(size: 9, color: FieldFramesTheme.paperDim)
            }
            Spacer(minLength: 0)
            if !library.isSelecting {
            Button { store.remove(ids: edited) } label: {
                Text("REMOVE DEVELOPED").ffLabel(size: 10, color: edited.isEmpty ? FieldFramesTheme.paperDim : FieldFramesTheme.lichen)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain).disabled(edited.isEmpty)
            Button { confirmClear = true } label: {
                Text("CLEAR").ffLabel(size: 10, color: store.count == 0 ? FieldFramesTheme.paperDim : FieldFramesTheme.lichen)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain).disabled(store.count == 0)
            }
            LibrarySelectControl(library: library)
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
    }

    private var grid: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - gutter * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gutter), count: columns), spacing: gutter) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        DevelopCell(manager: gallery.covers.manager, options: gallery.covers.options, asset: asset,
                                    pixels: cell * displayScale, edited: edited.contains(asset.localIdentifier))
                            .aspectRatio(1, contentMode: .fit)
                            .libraryCell(library, asset: asset, gallery: gallery, showsFavorite: false)
                            .onTapGesture { if !library.handleTap(asset) { Task { await gallery.open(asset, in: editor) } } }
                    }
                }
            }
        }
    }

    /// Fetches the queued assets (queue order) and which of them carry Mira adjustment data, off the main actor.
    private func reload() async {
        let ids = store.queue.ids
        let scope = gallery.scope
        let result = await Task.detached(priority: .userInitiated) { () -> ([Unchecked<PHAsset>], Set<String>) in
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: DevelopStore.allSourcesOptions())
            let wanted = SidebarLoader.sourceTypes(for: scope)
            var byID: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in
                if wanted == nil || !asset.sourceType.isDisjoint(with: wanted!) { byID[asset.localIdentifier] = asset }
            }
            let ordered = ids.compactMap { byID[$0] }
            let done = Set(ordered.filter { GalleryKit.isEdited(Unchecked(value: $0)) }.map(\.localIdentifier))
            return (ordered.map { Unchecked(value: $0) }, done)
        }.value
        guard !Task.isCancelled else { return }
        assets = result.0.map(\.value)
        edited = result.1
        library.selection.prune(keeping: Set(assets.map(\.localIdentifier)))
        loaded = true
    }
}

private struct DevelopCell: View {
    let manager: PHCachingImageManager
    let options: PHImageRequestOptions
    let asset: PHAsset
    let pixels: CGFloat
    let edited: Bool
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color(white: 0.1)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomTrailing) {
                if edited {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FieldFramesTheme.lichen)
                        .padding(4).background(Color.black.opacity(0.6)).padding(4)
                        .accessibilityLabel("Developed")
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: "\(asset.localIdentifier)|\(Int(pixels))") { request() }
            .onDisappear {
                if let id = requestID { manager.cancelImageRequest(id) }
                requestID = nil
            }
    }

    private func request() {
        guard image == nil else { return }
        ThumbnailMetrics.shared.recordRequest()
        requestID = GalleryKit.requestThumbnail(
            manager: manager, asset: Unchecked(value: asset), size: CGSize(width: pixels, height: pixels),
            options: Unchecked(value: options)
        ) { box, _ in
            MainActor.assumeIsolated { if let img = box.value { image = img } }
        }
    }
}
