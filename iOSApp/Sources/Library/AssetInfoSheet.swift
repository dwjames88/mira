import CoreLocation
import MapKit
import MiraCore
import MiraUI
import Photos
import SwiftUI

private typealias T = FieldFramesTheme

/// INFO for one photo: Cormorant filename and date, then mono label / value rows grouped by hairlines,
/// a FAVORITE toggle and the albums the photo is in. Plain values and closures (snapshot-friendly).
struct AssetInfoSheet: View {
    let info: AssetInfo
    let albumTitles: [String]
    var onToggleFavorite: () -> Void = {}
    var onClose: () -> Void = {}

    /// Rows are grouped like the formatter orders them.
    private static let groups: [[String]] = [
        ["DATE"], ["CAMERA", "LENS", "EXPOSURE"], ["DIMENSIONS", "FILE SIZE", "FORMAT"], ["LOCATION"], ["FILENAME"],
    ]

    private var grouped: [[AssetInfoRow]] {
        let rows = AssetInfoFormatter.rows(info)
        return Self.groups.map { labels in rows.filter { labels.contains($0.label) } }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHandle(label: "Close info", onClose: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.filename.isEmpty ? "Photo" : (info.filename as NSString).deletingPathExtension)
                        .font(T.display(30, weight: .regular)).foregroundStyle(T.paper).lineLimit(2)
                    HStack(spacing: T.cells(1)) {
                        Text(info.creationDate.map { AssetInfoFormatter.date($0) } ?? "DATE UNKNOWN")
                            .ffLabel(size: 10, color: T.paperDim)
                        if info.hasMiraEdit { tag("EDITED IN MIRA") } else if info.hasAdjustments { tag("EDITED") }
                        if info.isRAW { tag("RAW") }
                    }
                    .padding(.top, 2).padding(.bottom, T.cells(2))

                    FFHairline()
                    Button(action: onToggleFavorite) {
                        HStack(spacing: T.cells(1)) {
                            Image(systemName: info.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13)).foregroundStyle(info.isFavorite ? T.lichen : T.paperDim)
                            Text("FAVORITE").ffLabel(size: 10, color: info.isFavorite ? T.paper : T.paperDim)
                            Spacer(minLength: 0)
                            Text(info.isFavorite ? "ON" : "OFF").ffLabel(size: 10, color: info.isFavorite ? T.lichen : T.paperDim)
                        }
                        .frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(info.isFavorite ? "On" : "Off")
                    .accessibilityIdentifier("library.info.favorite")
                    FFHairline()

                    ForEach(Array(grouped.enumerated()), id: \.offset) { _, rows in
                        VStack(spacing: 0) {
                            ForEach(rows, id: \.label) { row in
                                HStack(alignment: .firstTextBaseline, spacing: T.cells(1)) {
                                    Text(row.label).ffLabel(size: 9, color: T.paperDim).frame(width: 92, alignment: .leading)
                                    Text(row.value).font(T.mono(12)).foregroundStyle(T.paper)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 7)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 4)
                        FFHairline()
                    }

                    FFSectionLabel("IN ALBUMS").padding(.top, T.cells(2))
                    if albumTitles.isEmpty {
                        Text("NOT IN ANY ALBUM").ffLabel(size: 10, color: T.paperDim).padding(.vertical, 8)
                    } else {
                        ForEach(albumTitles, id: \.self) { title in
                            Text(title).font(T.display(18, weight: .regular)).foregroundStyle(T.paper)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, T.cells(2)).padding(.bottom, T.cells(3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ffSheet()
    }

    private func tag(_ text: String) -> some View {
        Text(text).ffLabel(size: 8, color: T.lichen)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(Rectangle().strokeBorder(T.lichen.opacity(0.6), lineWidth: 1))
    }
}

/// The real sheet: reads the info off the main actor, resolves a place name, follows the favorite flag.
struct AssetInfoHost: View {
    let assetID: String
    @Environment(\.dismiss) private var dismiss
    @State private var info: AssetInfo?
    @State private var albumTitles: [String] = []

    var body: some View {
        Group {
            if let info {
                AssetInfoSheet(info: info, albumTitles: albumTitles, onToggleFavorite: toggle, onClose: { dismiss() })
            } else {
                Color.clear.ffSheet()
            }
        }
        .task { await load() }
    }

    private func load() async {
        let id = assetID
        guard var read = await AssetInfoReader.read(id: id) else { dismiss(); return }
        let titles = await Task.detached(priority: .userInitiated) { Self.albumTitles(containing: id) }.value
        info = read
        albumTitles = titles
        if let lat = read.latitude, let lon = read.longitude {
            if let name = await PlaceName.resolve(latitude: lat, longitude: lon) {
                read.locationName = name
                info = read
            }
        }
    }

    private func toggle() {
        guard var current = info else { return }
        let on = !current.isFavorite
        current.isFavorite = on
        info = current
        let id = assetID
        Task {
            do { try await LibraryActions.setFavorite([id], on) }
            catch {
                if let actual = LibraryActions.isFavorite(id: id) { info?.isFavorite = actual }
            }
        }
    }

    private nonisolated static func albumTitles(containing id: String) -> [String] {
        let ids = LibraryActions.albumIDs(containing: id)
        guard !ids.isEmpty else { return [] }
        return LibraryActions.userAlbums().filter { ids.contains($0.id) }.map(\.displayPath)
    }
}

/// A place name from coordinates with MapKit's reverse geocoder (iOS 26+); nil on older systems or failure,
/// when the sheet keeps showing coordinates.
enum PlaceName {
    @MainActor
    static func resolve(latitude: Double, longitude: Double) async -> String? {
        guard #available(iOS 26.0, *) else { return nil }
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else { return nil }
        guard let items = try? await request.mapItems, let item = items.first else { return nil }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty { return city }
        if let short = item.address?.shortAddress, !short.isEmpty { return short }
        return item.name
    }
}
