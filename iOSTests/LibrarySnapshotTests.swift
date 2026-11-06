import MiraCore
import MiraUI
import SwiftUI
import XCTest
@testable import Mira

private typealias T = FieldFramesTheme

@MainActor
final class LibrarySnapshotTests: XCTestCase {
    // MARK: Stubs

    private func fixtureCell(_ index: Int, selected: Bool, favorite: Bool) -> some View {
        let shade = 0.10 + 0.05 * Double(index % 6)
        return Color(white: shade)
            .overlay { Image(uiImage: LayoutSnapshotTests.sample).resizable().scaledToFill().opacity(index % 3 == 0 ? 0.9 : 0.5) }
            .overlay(alignment: .bottomTrailing) { if favorite { LibraryFavoriteChip().padding(4) } }
            .overlay { if selected { LibrarySelectedOverlay() } }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
    }

    private func gridScreen(selecting: Bool, selected: Set<Int>, items: [LibraryActionItem], frames: FrameBox) -> some View {
        VStack(spacing: 0) {
            HStack {
                if selecting {
                    LibrarySelectionStatus(count: selected.count)
                } else {
                    Text("128 PHOTOS").ffLabel(size: 9, color: T.paperDim)
                }
                Spacer(minLength: 0)
                if !selecting {
                    FFTabBar([(value: false, title: "ALL"), (value: true, title: "RAW 12")],
                             selection: .constant(false), spacing: T.cells(2))
                }
                LibrarySelectToggle(isSelecting: selecting) {}
            }
            .padding(.horizontal, T.cells(2)).frame(height: 32)
            FFHairline()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
                    ForEach(0..<30, id: \.self) { i in
                        self.fixtureCell(i, selected: selected.contains(i), favorite: i % 4 == 1)
                    }
                }
            }
            if selecting {
                LibrarySelectionBar(items: items) { _ in }
                    .background(GeometryReader { g in
                        Color.clear.onAppear { frames.frames["bar"] = g.frame(in: .global) }
                    })
            }
        }
        .background(FFGroundBackground(grain: 0.07))
    }

    private func items(count: Int, nodeID: String = "all", limited: Bool = false, caps: AlbumCapabilities? = nil) -> [LibraryActionItem] {
        LibraryActionAvailability.items(for: GallerySelectionModel.context(
            nodeID: nodeID, limitedAccess: limited, capabilities: caps, count: count, allFavorite: false, allHidden: false))
    }

    // MARK: Select bar

    func testSelectBarSnapshot() async {
        for d in TestDevice.all {
            let frames = FrameBox()
            let view = gridScreen(selecting: true, selected: [1, 2, 5, 7], items: items(count: 4), frames: frames)
            await Snapshot.render(view, device: d, name: "library-select-bar")
            let bar = try! XCTUnwrap(frames.frames["bar"], "bar frame")
            XCTAssertLessThanOrEqual(bar.maxY, d.size.height - d.bottomInset + 0.5, "bar stays inside the screen on \(d.name)")
            XCTAssertGreaterThanOrEqual(bar.minX, -0.5)
            XCTAssertLessThanOrEqual(bar.maxX, d.size.width + 0.5)
            XCTAssertGreaterThanOrEqual(bar.height, 48, "bar has a 44 pt hit row")
        }
    }

    func testBarActionsFollowAvailability() {
        // Library: FAVORITE / ALBUM / DELETE / SHARE on the bar, the rest under MORE.
        let library = items(count: 2)
        XCTAssertEqual(library.filter { LibrarySelectionBar.barTitle($0.action) == "ALBUM" }.count, 1)
        XCTAssertTrue(library.contains { $0.action == .hide })
        // Limited access: no album actions at all.
        let limited = items(count: 2, limited: true)
        XCTAssertFalse(limited.contains { $0.action == .addToAlbum || $0.action == .moveToAlbum || $0.action == .removeFromAlbum })
        // Recently Deleted: only INFO.
        let deleted = items(count: 1, nodeID: SidebarLoader.smartID(SidebarLoader.recentlyDeletedRaw))
        XCTAssertEqual(deleted.map(\.action), [.info])
        // Hidden album: UNHIDE.
        let hidden = items(count: 1, nodeID: SidebarLoader.smartID(SidebarLoader.hiddenRaw))
        XCTAssertTrue(hidden.contains { $0.action == .unhide })
        XCTAssertFalse(hidden.contains { $0.action == .hide })
        // A user album with full rights: MOVE and REMOVE appear; a smart album never gets them.
        let album = items(count: 1, nodeID: "ABC/L0/040", caps: .full)
        XCTAssertTrue(album.contains { $0.action == .moveToAlbum } && album.contains { $0.action == .removeFromAlbum })
        let smart = items(count: 1, nodeID: "smart:2")
        XCTAssertFalse(smart.contains { $0.action == .moveToAlbum || $0.action == .removeFromAlbum })
        // Nothing selected: everything disabled.
        XCTAssertTrue(items(count: 0).allSatisfy { !$0.isEnabled })
    }

    // MARK: Album sheet

    private static let albums: [AlbumEntry] = [
        AlbumEntry(id: "a", title: "Iceland 2026", path: ["Trips"], count: 214),
        AlbumEntry(id: "b", title: "Portra 400", count: 38),
        AlbumEntry(id: "c", title: "Contact sheets", path: ["Film", "Scans"], count: 1204),
        AlbumEntry(id: "d", title: "Kodak Gold on a very long title that has to truncate nicely", count: 7),
    ]

    func testAlbumSheetSnapshot() async {
        for d in TestDevice.all {
            let view = AlbumPickerSheet(
                mode: .move, count: 3, albums: Self.albums, isLoading: false, defaultName: "Untitled Album",
                onPick: { _ in }, onCreate: { _ in }, onClose: {}
            ) { _ in Color(white: 0.16) }
            await Snapshot.render(view, device: d, name: "library-album-sheet")
        }
        let titles = Self.albums.map(\.title)
        XCTAssertEqual(AlbumList.uniqueTitle(existing: titles + ["Untitled Album"]), "Untitled Album 2")
        XCTAssertEqual(AlbumList.targets(for: Self.albums, excluding: "a").count, 3)
    }

    // MARK: Info sheet

    func testInfoSheetSnapshot() async {
        var info = AssetInfo(
            filename: "IMG_4021.DNG", creationDate: Date(timeIntervalSince1970: 1_790_000_000),
            cameraName: "Apple iPhone 15 Pro", lens: "iPhone 15 Pro back camera 6.76mm f/1.78",
            focalLength: 24, fNumber: 1.8, exposureTime: 1.0 / 250, iso: 64, pixelWidth: 8064, pixelHeight: 6048,
            fileSize: 25_600_000, formats: ["RAW", "JPEG"], isRAW: true, isFavorite: true,
            hasAdjustments: true, hasMiraEdit: true, latitude: 64.1466, longitude: -21.9426)
        info.locationName = "Reykjavik, Iceland"
        for d in TestDevice.all {
            let view = AssetInfoSheet(info: info, albumTitles: ["Trips › Iceland 2026", "Portra 400"])
            await Snapshot.render(view, device: d, name: "library-info-sheet")
        }
        let rows = AssetInfoFormatter.rows(info)
        XCTAssertTrue(rows.contains { $0.label == "LOCATION" && $0.value == "Reykjavik, Iceland" })
    }

    // MARK: Thumbnails are not re-requested for metadata-only changes

    func testMetadataOnlyChangeKeepsThumbnailKey() {
        let id = "ASSET/L0/001"
        let before = Date(timeIntervalSinceReferenceDate: 1000)
        let after = Date(timeIntervalSinceReferenceDate: 2000)   // PhotoKit moves the date on a favorite
        var versions = AssetVersions()
        let key0 = GridThumbnailKey(id: id, pixels: 300, modificationDate: before, versions: versions)

        // Favorite: changed, pixels untouched.
        let meta = LibraryChangeSummary(isIncremental: true, changedIDs: [id], contentChangedIDs: [])
        versions.apply(meta, previousModification: { _ in before })
        XCTAssertEqual(GridThumbnailKey(id: id, pixels: 300, modificationDate: after, versions: versions), key0,
                       "a favorite / hide / album change keeps the key, so the cell does not re-request")

        // A real edit: the key changes.
        let edit = LibraryChangeSummary(isIncremental: true, changedIDs: [id], contentChangedIDs: [id])
        versions.apply(edit, previousModification: { _ in before })
        XCTAssertNotEqual(GridThumbnailKey(id: id, pixels: 300, modificationDate: after, versions: versions), key0,
                          "an edit changes the key")
    }

    // MARK: Selection pruning

    func testSelectionPrunesAssetsThatLeft() {
        var selection = LibrarySelection()
        selection.isSelecting = true
        for id in ["a", "b", "c"] { selection.toggle(id) }
        selection.prune(keeping: ["a", "c"])
        XCTAssertEqual(selection.ids, ["a", "c"])
        XCTAssertTrue(selection.isSelecting)
    }
}
