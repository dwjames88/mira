import MiraUI
import Photos
import PhotosUI
import SwiftUI

struct GalleryView: View {
    @Bindable var editor: EditorViewModel
    @State private var gallery = GalleryModel()
    @State private var pickerItem: PhotosPickerItem?
    @Environment(\.displayScale) private var displayScale

    private let columns = 3
    private let gutter: CGFloat = 1

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                FFHairline()
                content
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

    private var header: some View {
        HStack(spacing: FieldFramesTheme.cells(1)) {
            Text("Mira").font(FieldFramesTheme.display(22, weight: .regular))
            Text(gallery.hasAccess ? "\(gallery.count) PHOTOS" : editor.status)
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
            if gallery.count == 0 {
                FFEmptyState(title: "No photos", subtitle: gallery.status == .limited
                             ? "NO PHOTOS IN YOUR SELECTION" : "YOUR LIBRARY HAS NO PICTURES")
            } else { grid }
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

    private var grid: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - gutter * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gutter), count: columns),
                          spacing: gutter) {
                    ForEach(0..<gallery.count, id: \.self) { index in
                        if let asset = gallery.asset(at: index) {
                            GalleryCell(gallery: gallery, asset: asset, index: index)
                                .aspectRatio(1, contentMode: .fit)
                                .onTapGesture { Task { await gallery.open(asset, in: editor) } }
                        }
                    }
                }
            }
            .onAppear { gallery.setThumbSize(CGSize(width: cell * displayScale, height: cell * displayScale)) }
            .onChange(of: cell) { _, c in gallery.setThumbSize(CGSize(width: c * displayScale, height: c * displayScale)) }
        }
    }
}

private struct GalleryCell: View {
    let gallery: GalleryModel
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
                gallery.updateCaching(around: index)
                guard image == nil else { return }
                request()
                let boxed = Unchecked(value: asset)
                Task.detached(priority: .utility) {
                    let found = GalleryKit.badges(of: boxed)
                    await MainActor.run { badges = found }
                }
            }
            .onDisappear {
                if let id = requestID { gallery.caching.cancelImageRequest(id) }
                requestID = nil
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text).ffLabel(size: 8, color: FieldFramesTheme.paper)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.black.opacity(0.6))
    }

    private func request() {
        let size = gallery.thumbSize == .zero ? CGSize(width: 300, height: 300) : gallery.thumbSize
        requestID = GalleryKit.requestThumbnail(
            manager: gallery.caching, asset: Unchecked(value: asset), size: size,
            options: Unchecked(value: gallery.thumbOptions)
        ) { box in
            MainActor.assumeIsolated { if let img = box.value { image = img } }
        }
    }
}

struct ImportLabel: View {
    var body: some View { Text("IMPORT").ffLabel(size: 11, color: FieldFramesTheme.paperDim) }
}
