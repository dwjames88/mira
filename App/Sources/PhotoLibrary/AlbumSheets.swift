import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// New Album and Rename Album: laid out like the Save Preset and Export sheets (display title,
/// FFSectionLabel, hairline-bordered mono field, `.ff` Cancel, `.ffProminent` Save).
struct AlbumNameSheet: View {
    let store: LibraryStore
    let request: AlbumSheetRequest
    @State private var name = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && !busy }
    private var isRename: Bool { if case .rename = request { true } else { false } }
    private var assetIDs: [String] { if case .new(let ids) = request { ids } else { [] } }

    var body: some View {
        VStack(alignment: .leading, spacing: T.rows(1)) {
            Text(isRename ? "Rename Album" : "New Album")
                .font(T.display(30, weight: .medium))
            FFHairline()
            FFSectionLabel("Name")
            TextField("", text: $name, prompt: Text("ALBUM NAME").font(T.mono(10)).foregroundColor(T.paperDim))
                .textFieldStyle(.plain)
                .font(T.mono(11))
                .foregroundStyle(T.paper)
                .padding(.horizontal, T.cells(1))
                .frame(height: T.rows(2))
                .overlay(Rectangle().strokeBorder(focused ? T.lichen : T.hair, lineWidth: 1))
                .focused($focused)
                .onSubmit(save)
                .accessibilityLabel("Album name")
            if !assetIDs.isEmpty {
                Text(assetIDs.count == 1 ? "1 PHOTO WILL BE ADDED" : "\(assetIDs.count) PHOTOS WILL BE ADDED")
                    .ffLabel(size: 9, color: T.paperDim)
            }
            HStack(spacing: T.cells(1)) {
                Spacer()
                Button("Cancel") { store.albumSheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.ff)
                Button(isRename ? "Rename" : "Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ffProminent)
                    .disabled(!canSave)
            }
        }
        .padding(T.cells(3))
        .frame(width: T.cells(44))
        .fieldFramesWindow()
        .onAppear {
            switch request {
            case .new:
                name = AlbumList.uniqueTitle("Untitled Album", existing: store.albums.map(\.title))
            case .rename(_, let title):
                name = title
            }
            focused = true
        }
    }

    private func save() {
        guard canSave else { return }
        busy = true
        let title = trimmed
        Task {
            let ok: Bool
            switch request {
            case .new(let ids): ok = await store.createAlbum(title: title, adding: ids)
            case .rename(let id, _): ok = await store.renameAlbum(id: id, title: title)
            }
            busy = false
            if ok { store.albumSheet = nil }
        }
    }
}
