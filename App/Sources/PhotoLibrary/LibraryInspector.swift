import CoreLocation
import MapKit
import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// The INFO panel beside the grid: 36 cells on the panel ground with a leading hairline. Describes the
/// primary selected photo (or "N PHOTOS SELECTED" with the shared favorite state) and follows the
/// selection and live library changes.
struct LibraryInspector: View {
    static let width = T.cells(36)
    let store: LibraryStore
    @State private var info: AssetInfo?
    @State private var place: String?
    @State private var albumTitles: [String] = []

    private struct InfoKey: Hashable { var id: String?; var version: Int }
    private struct StateKey: Hashable { var id: String?; var tick: Int; var albums: Int }

    var body: some View {
        let count = store.selection.count
        HStack(spacing: 0) {
            FFHairline(.vertical)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Info").ffLabel(color: T.paperDim)
                    Spacer()
                    Button { store.inspectorOpen = false } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(T.paperMid)
                            .frame(width: T.cells(2), height: T.rows(1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close the info panel \u{2318}I")
                    .accessibilityLabel("Close info")
                }
                .padding(.horizontal, T.cells(2))
                .frame(height: T.rows(2))
                FFHairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: T.rows(0.5)) {
                        if count == 0 {
                            Text("Select a photo to see its details").ffLabel(size: 10)
                        } else if count == 1 {
                            single
                        } else {
                            multiple(count)
                        }
                    }
                    .padding(T.cells(2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: Self.width - 1)
            .background { FFPanelBackground() }
        }
        .frame(width: Self.width)
        .task(id: InfoKey(id: store.primaryID, version: store.primaryID.map { store.versions[$0] } ?? 0)) {
            await loadInfo()
        }
        .task(id: StateKey(id: store.primaryID, tick: store.changeTick, albums: store.albums.count)) {
            await loadAlbums()
        }
    }

    // MARK: One photo

    @ViewBuilder private var single: some View {
        if store.primaryID != nil {
            let shown = info.map { merged($0) }
            Text(shown?.filename.isEmpty == false ? shown!.filename : "Photo")
                .font(T.display(21, weight: .medium))
                .foregroundStyle(T.paper)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let shown {
                if shown.hasMiraEdit || shown.hasAdjustments {
                    Text(shown.hasMiraEdit ? "EDITED WITH MIRA" : "EDITED").ffLabel(size: 10, color: T.lichen)
                }
                FFSectionLabel("Details")
                ForEach(AssetInfoFormatter.rows(shown).filter { $0.label != "FILENAME" }, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: T.cells(1)) {
                        Text(row.label).ffLabel(size: 9).frame(width: T.cells(10), alignment: .leading)
                        Text(row.value)
                            .font(T.mono(11))
                            .foregroundStyle(T.paperSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("READING").ffLabel(size: 10)
            }
            FFSectionLabel("Photos")
            FFToggle("Favorite", isOn: favoriteBinding)
            FFSectionLabel("In albums", trailing: albumTitles.isEmpty ? nil : "\(albumTitles.count)")
            if albumTitles.isEmpty {
                Text("NONE").ffLabel(size: 10)
            } else {
                ForEach(albumTitles, id: \.self) { title in
                    Text(title).font(.system(size: 13)).foregroundStyle(T.paperMid).lineLimit(1)
                }
            }
        }
    }

    // MARK: Several photos

    @ViewBuilder private func multiple(_ count: Int) -> some View {
        Text("\(count) photos selected")
            .font(T.display(21, weight: .medium))
            .foregroundStyle(T.paper)
        FFSectionLabel("Photos")
        FFToggle(store.selectionFlags.allFavorite ? "Favorite" : "Favorite all", isOn: favoriteBinding)
        Text(store.selectionFlags.allFavorite ? "ALL ARE FAVORITES" : "NOT ALL ARE FAVORITES").ffLabel(size: 9)
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(get: { store.selectionFlags.allFavorite },
                set: { store.setFavorite(store.selection.ids, $0) })
    }

    // MARK: Loading

    private func merged(_ info: AssetInfo) -> AssetInfo {
        var copy = info
        copy.locationName = place
        return copy
    }

    private func loadInfo() async {
        guard store.selection.count == 1, let id = store.primaryID else { info = nil; place = nil; return }
        let read = await AssetInfoReader.read(id: id)
        guard !Task.isCancelled else { return }
        if info?.latitude != read?.latitude || info?.longitude != read?.longitude { place = nil }
        info = read
        guard let read, let lat = read.latitude, let lon = read.longitude,
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon)) else { return }
        // A place name is a nicety: on any failure the formatter keeps showing the coordinates.
        let items = (try? await request.mapItems) ?? []
        guard !Task.isCancelled else { request.cancel(); return }
        if let address = items.first?.address {
            place = address.shortAddress ?? address.fullAddress
        }
    }

    private func loadAlbums() async {
        guard store.selection.count == 1, let id = store.primaryID else { albumTitles = []; return }
        let ids = await Task.detached(priority: .userInitiated) { LibraryActions.albumIDs(containing: id) }.value
        guard !Task.isCancelled else { return }
        let byID = Dictionary(store.albums.map { ($0.id, $0.displayPath) }, uniquingKeysWith: { first, _ in first })
        albumTitles = ids.compactMap { byID[$0] }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
