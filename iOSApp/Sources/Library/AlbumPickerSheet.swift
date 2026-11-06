import MiraCore
import MiraUI
import Photos
import SwiftUI
import UIKit

private typealias T = FieldFramesTheme

/// The sheet's top edge: a chevron to close (the camera doors' handle).
struct SheetHandle: View {
    let label: String
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(T.paperMid)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension View {
    /// The look of the camera doors for a system sheet: ink-soft with grain, square corners, no grabber.
    func ffSheet(detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.hidden)
            .presentationBackground { FFPanelBackground() }
            .presentationCornerRadius(0)
            .preferredColorScheme(.dark)
    }
}

/// A mono search / name field with a hairline border.
struct FFMonoField: View {
    let prompt: String
    @Binding var text: String
    var submitLabel: SubmitLabel = .done
    var onSubmit: () -> Void = {}
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        TextField("", text: $text,
                  prompt: Text(prompt.uppercased()).font(T.mono(12)).foregroundStyle(T.paperDim))
            .font(T.mono(13))
            .foregroundStyle(T.paper)
            .tint(T.lichen)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .padding(.horizontal, T.cells(1.5))
            .frame(height: 40)
            .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
    }
}

/// ADD TO ALBUM / MOVE TO ALBUM. Plain values and closures only, so a snapshot can render it with stubs.
struct AlbumPickerSheet<Cover: View>: View {
    let mode: AlbumSheetRequest.Mode
    let count: Int
    /// Albums that can take the photos (already filtered with `AlbumList.targets`).
    let albums: [AlbumEntry]
    let isLoading: Bool
    /// Default name offered by the NEW ALBUM row.
    let defaultName: String
    var onPick: (AlbumEntry) -> Void
    var onCreate: (String) -> Void
    var onClose: () -> Void
    @ViewBuilder var cover: (AlbumEntry) -> Cover

    @State private var query = ""
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var shown: [AlbumEntry] { AlbumList.filter(albums, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHandle(label: "Close", onClose: onClose)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .add ? "Add to album" : "Move to album")
                    .font(T.display(30, weight: .regular)).foregroundStyle(T.paper)
                Text("\(count) \(count == 1 ? "PHOTO" : "PHOTOS")").ffLabel(size: 10, color: T.paperDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, T.cells(2)).padding(.bottom, T.cells(1.5))
            FFMonoField(prompt: "Search albums", text: $query)
                .padding(.horizontal, T.cells(2)).padding(.bottom, T.cells(1.5))
                .accessibilityIdentifier("library.albumSearch")
            FFHairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    newAlbumRow
                    FFHairline().padding(.leading, T.cells(2))
                    if isLoading {
                        Text("LOADING ALBUMS").ffLabel(size: 10).padding(T.cells(2))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if shown.isEmpty {
                        Text(albums.isEmpty ? "NO OTHER ALBUMS" : "NO MATCHING ALBUMS").ffLabel(size: 10)
                            .padding(T.cells(2)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(shown) { album in
                        Button { onPick(album) } label: { row(album) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.album.\(album.title)")
                        FFHairline().padding(.leading, T.cells(2))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ffSheet()
    }

    @ViewBuilder private var newAlbumRow: some View {
        if naming {
            HStack(spacing: T.cells(1.5)) {
                FFMonoField(prompt: "Album name", text: $name, submitLabel: .done, onSubmit: commit, capitalization: .words)
                    .focused($nameFocused)
                    .accessibilityIdentifier("library.newAlbumName")
                Button(action: commit) {
                    Text("CREATE").ffLabel(size: 11, color: T.lichen, weight: .medium).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, T.cells(2)).padding(.vertical, T.cells(1))
        } else {
            Button {
                name = defaultName
                naming = true
                nameFocused = true
            } label: {
                HStack(spacing: T.cells(1.5)) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .light)).foregroundStyle(T.lichen)
                        .frame(width: 48, height: 48)
                        .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
                    Text("NEW ALBUM").ffLabel(size: 11, color: T.lichen, weight: .medium)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, T.cells(2)).padding(.vertical, 6)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.newAlbum")
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }

    private func row(_ album: AlbumEntry) -> some View {
        HStack(spacing: T.cells(1.5)) {
            cover(album)
                .frame(width: 48, height: 48)
                .clipped()
                .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(T.display(19, weight: .regular)).foregroundStyle(T.paper).lineLimit(1)
                if !album.path.isEmpty {
                    Text(album.path.joined(separator: " › ")).ffLabel(size: 9, color: T.paperDim).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text("\(album.count)").ffLabel(size: 10, color: T.paperDim)
        }
        .padding(.horizontal, T.cells(2)).padding(.vertical, 6)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// The real sheet: loads the user's albums off the main actor and reports the choice.
struct AlbumPickerHost: View {
    let request: AlbumSheetRequest
    /// (existing album id, nil) or (nil, new album title).
    var onComplete: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [AlbumEntry] = []
    @State private var allTitles: [String] = []
    @State private var loading = true

    var body: some View {
        AlbumPickerSheet(
            mode: request.mode, count: request.assetIDs.count, albums: albums, isLoading: loading,
            defaultName: AlbumList.uniqueTitle(existing: allTitles),
            onPick: { album in onComplete(album.id, nil); dismiss() },
            onCreate: { title in onComplete(nil, title); dismiss() },
            onClose: { dismiss() }
        ) { album in
            AlbumSheetCover(albumID: album.id)
        }
        .task {
            let current = request.sourceAlbumID
            let loaded = await Task.detached(priority: .userInitiated) { LibraryActions.userAlbums() }.value
            allTitles = loaded.map(\.title)
            albums = AlbumList.targets(for: loaded, excluding: current)
            loading = false
        }
    }
}

/// A small cover for the sheet's rows: the album's key asset (or newest picture), loaded off the main actor.
struct AlbumSheetCover: View {
    let albumID: String
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.09)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").font(.system(size: 12, weight: .light)).foregroundStyle(T.paperDim.opacity(0.5)) }
            }
            .task(id: albumID) {
                let side = 48 * displayScale
                let found = await Task.detached(priority: .userInitiated) { GalleryKit.coverAsset(nodeID: albumID) }.value
                guard let found else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                _ = GalleryKit.requestThumbnail(
                    manager: PHImageManager.default(), asset: found, size: CGSize(width: side, height: side),
                    options: Unchecked(value: options)
                ) { box, _ in
                    MainActor.assumeIsolated { if let img = box.value { image = img } }
                }
            }
    }
}
