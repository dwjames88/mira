import Foundation
import Testing
@testable import MiraCore

private let ids = ["a", "b", "c", "d", "e"]

@Suite("Library selection")
struct LibrarySelectionTests {
    @Test func toggleKeepsSelectionOrder() {
        var s = LibrarySelection()
        s.toggle("c"); s.toggle("a"); s.toggle("e")
        #expect(s.ids == ["c", "a", "e"])
        #expect(s.count == 3 && s.contains("a") && !s.contains("b"))
        s.toggle("a")
        #expect(s.ids == ["c", "e"])
        #expect(s.anchor == "e")
    }

    @Test func selectReplaces() {
        var s = LibrarySelection()
        s.toggle("a"); s.toggle("b")
        s.select("d")
        #expect(s.ids == ["d"] && s.anchor == "d")
    }

    @Test func rangeFromAnchorForward() {
        var s = LibrarySelection()
        s.select("b")
        s.selectRange(to: "d", in: ids)
        #expect(s.ids == ["b", "c", "d"])
        #expect(s.anchor == "b")
    }

    @Test func rangeFromAnchorBackward() {
        var s = LibrarySelection()
        s.select("d")
        s.selectRange(to: "b", in: ids)
        #expect(s.ids == ["d", "c", "b"])
    }

    @Test func rangeWithoutAnchorSelectsOne() {
        var s = LibrarySelection()
        s.selectRange(to: "c", in: ids)
        #expect(s.ids == ["c"])
        var t = LibrarySelection()
        t.select("zzz")
        t.selectRange(to: "c", in: ids)
        #expect(t.ids == ["c"])
    }

    @Test func rangeDoesNotDuplicate() {
        var s = LibrarySelection()
        s.toggle("c"); s.toggle("a")
        s.selectRange(to: "c", in: ids)
        #expect(s.ids == ["c", "a", "b"])
    }

    @Test func selectAllAndClear() {
        var s = LibrarySelection()
        s.selectAll(ids)
        #expect(s.ids == ids && s.count == 5)
        s.isSelecting = true
        s.clear()
        #expect(s.isEmpty && s.anchor == nil && s.isSelecting)
        s.finishSelecting()
        #expect(!s.isSelecting)
    }

    @Test func pruneDropsGoneIDsAndAnchor() {
        var s = LibrarySelection()
        s.selectAll(ids)
        s.select("b")
        s.toggle("c"); s.toggle("d")
        s.prune(keeping: ["a", "b", "d"])
        #expect(s.ids == ["b", "d"])
        #expect(s.anchor == "d")
        s.prune(keeping: ["a", "d"])
        #expect(s.ids == ["d"])
        s.prune(keeping: [])
        #expect(s.isEmpty && s.anchor == nil)
    }
}

@Suite("Library action availability")
struct LibraryActionAvailabilityTests {
    private func actions(_ c: LibraryActionContext) -> [LibraryAction] { LibraryActionAvailability.items(for: c).map(\.action) }

    @Test func userAlbumWithFullRights() {
        let c = LibraryActionContext(nodeKind: .album, nodeID: "alb", albumCapabilities: .full, selectionCount: 2)
        #expect(actions(c) == [.favorite, .addToAlbum, .moveToAlbum, .removeFromAlbum, .hide, .duplicate, .info, .share, .delete])
        let items = LibraryActionAvailability.items(for: c)
        #expect(items.first { $0.action == .info }?.isEnabled == false)
        #expect(items.first { $0.action == .delete }?.isEnabled == true)
        #expect(items.first { $0.action == .delete }?.isDestructive == true)
    }

    @Test func albumWithoutRemoveHasNoMoveOrRemove() {
        let caps = AlbumCapabilities(canAdd: true, canRemove: false, canRename: false, canDelete: false)
        let c = LibraryActionContext(nodeKind: .album, albumCapabilities: caps, selectionCount: 1)
        #expect(!actions(c).contains(.moveToAlbum) && !actions(c).contains(.removeFromAlbum))
    }

    @Test func libraryFavoritesAndSmartAlbumsHaveNoMove() {
        for kind in [SidebarNodeKind.library, .favorites, .recents, .smart(1)] {
            let c = LibraryActionContext(nodeKind: kind, selectionCount: 1)
            #expect(actions(c) == [.favorite, .addToAlbum, .hide, .duplicate, .info, .share, .delete])
        }
    }

    @Test func allFavoriteSaysUnfavorite() {
        let c = LibraryActionContext(nodeKind: .favorites, selectionCount: 3, allFavorite: true)
        let first = LibraryActionAvailability.items(for: c).first
        #expect(first?.action == .unfavorite && first?.title == "UNFAVORITE" && first?.systemImage == "heart.slash")
        #expect(LibraryAction.favorite.title == "FAVORITE")
    }

    @Test func hiddenAlbumOrAllHiddenSaysUnhide() {
        let a = LibraryActionContext(nodeKind: .smart(0), isHiddenAlbum: true, selectionCount: 1)
        #expect(actions(a).contains(.unhide) && !actions(a).contains(.hide))
        let b = LibraryActionContext(nodeKind: .library, selectionCount: 1, allHidden: true)
        #expect(actions(b).contains(.unhide))
        #expect(LibraryAction.unhide.title == "UNHIDE" && LibraryAction.unhide.systemImage == "eye")
    }

    @Test func recentlyDeletedOffersOnlyInfo() {
        let one = LibraryActionContext(nodeKind: .smart(1000), isReadOnly: true, selectionCount: 1)
        #expect(LibraryActionAvailability.items(for: one) == [LibraryActionItem(action: .info, isEnabled: true)])
        let many = LibraryActionContext(nodeKind: .smart(1000), isReadOnly: true, selectionCount: 4)
        #expect(LibraryActionAvailability.items(for: many).allSatisfy { !$0.isEnabled })
    }

    @Test func limitedAccessHasNoAlbumActions() {
        let c = LibraryActionContext(nodeKind: .library, albumCapabilities: .full, limitedAccess: true, selectionCount: 2)
        #expect(actions(c) == [.favorite, .hide, .duplicate, .info, .share, .delete])
        #expect(!LibraryActionAvailability.canManageAlbums(limitedAccess: true))
        // Even if a stale context says "album", limited access wins.
        let stale = LibraryActionContext(nodeKind: .album, albumCapabilities: .full, limitedAccess: true, selectionCount: 2)
        #expect(!actions(stale).contains(.moveToAlbum) && !actions(stale).contains(.addToAlbum))
    }

    @Test func selectionCountEnablesActions() {
        let none = LibraryActionContext(nodeKind: .library, selectionCount: 0)
        #expect(LibraryActionAvailability.items(for: none).allSatisfy { !$0.isEnabled })
        let one = LibraryActionContext(nodeKind: .library, selectionCount: 1)
        #expect(LibraryActionAvailability.items(for: one).allSatisfy { $0.isEnabled })
        let many = LibraryActionContext(nodeKind: .library, selectionCount: 9)
        let info = LibraryActionAvailability.items(for: many).first { $0.action == .info }
        #expect(info?.isEnabled == false)
        #expect(LibraryActionAvailability.items(for: many).filter(\.isEnabled).count == 6)
    }

    @Test func everyActionHasTitleAndSymbol() {
        for a in LibraryAction.allCases { #expect(!a.title.isEmpty && !a.systemImage.isEmpty && a.title == a.title.uppercased()) }
    }
}

@Suite("Album list")
struct AlbumListTests {
    private let albums = [
        AlbumEntry(id: "1", title: "Paris", path: ["Trips", "2026"], count: 10),
        AlbumEntry(id: "2", title: "Café", path: [], count: 3),
        AlbumEntry(id: "3", title: "Shared", count: 5, capabilities: .none),
        AlbumEntry(id: "4", title: "Paris Food", count: 0),
    ]

    @Test func displayPath() {
        #expect(albums[0].displayPath == "Trips › 2026 › Paris")
        #expect(albums[1].displayPath == "Café")
    }

    @Test func targetsExcludeCurrentAndReadOnly() {
        #expect(AlbumList.targets(for: albums, excluding: "1").map(\.id) == ["2", "4"])
        #expect(AlbumList.targets(for: albums).map(\.id) == ["1", "2", "4"])
    }

    @Test func filterIsCaseAndDiacriticInsensitive() {
        #expect(AlbumList.filter(albums, query: "paris").map(\.id) == ["1", "4"])
        #expect(AlbumList.filter(albums, query: "CAFE").map(\.id) == ["2"])
        #expect(AlbumList.filter(albums, query: "trips").map(\.id) == ["1"])
        #expect(AlbumList.filter(albums, query: "  ").count == 4)
        #expect(AlbumList.filter(albums, query: "zzz").isEmpty)
    }

    @Test func diffByID() {
        var new = albums
        new.remove(at: 2)
        new[0].title = "Paris 2"
        new[1].count = 4
        new.append(AlbumEntry(id: "9", title: "New"))
        let d = AlbumList.diff(old: albums, new: new)
        #expect(d.inserted.map(\.id) == ["9"])
        #expect(d.removed.map(\.id) == ["3"])
        #expect(d.renamed.map(\.id) == ["1"])
        #expect(d.countChanged.map(\.id) == ["2"])
        #expect(AlbumList.diff(old: albums, new: albums).isEmpty)
    }

    @Test func uniqueTitle() {
        #expect(AlbumList.uniqueTitle("Untitled Album", existing: []) == "Untitled Album")
        #expect(AlbumList.uniqueTitle("Untitled Album", existing: ["untitled album"]) == "Untitled Album 2")
        #expect(AlbumList.uniqueTitle("Untitled Album", existing: ["Untitled Album", "Untitled Album 2", "Untitled Album 4"]) == "Untitled Album 3")
    }
}

@Suite("Asset info")
struct AssetInfoFormatterTests {
    private func value(_ label: String, _ info: AssetInfo) -> String? {
        AssetInfoFormatter.rows(info, timeZone: TimeZone(identifier: "UTC")!).first { $0.label == label }?.value
    }

    @Test func shutterFractions() {
        #expect(AssetInfoFormatter.shutter(1.0 / 8000) == "1/8000 s")
        #expect(AssetInfoFormatter.shutter(1.0 / 250) == "1/250 s")
        #expect(AssetInfoFormatter.shutter(1.0 / 3) == "1/3 s")
        #expect(AssetInfoFormatter.shutter(0.5) == "1/2 s")
        #expect(AssetInfoFormatter.shutter(2) == "2 s")
        #expect(AssetInfoFormatter.shutter(30) == "30 s")
        #expect(AssetInfoFormatter.shutter(1.5) == "1.5 s")
        #expect(AssetInfoFormatter.shutter(1) == "1 s")
        #expect(AssetInfoFormatter.shutter(0.8) == "0.8 s")
    }

    @Test func garbageExposureValuesDoNotTrap() {
        // 1 / 1e-30 and 1e30 overflow Int; corrupt EXIF can carry them.
        #expect(AssetInfoFormatter.shutter(1e-30) == "0 s")
        #expect(AssetInfoFormatter.shutter(.leastNonzeroMagnitude) == "0 s")
        #expect(!AssetInfoFormatter.shutter(1e30).isEmpty)
        let info = AssetInfo(focalLength: 1e30, fNumber: .infinity)
        #expect(AssetInfoFormatter.rows(info, timeZone: TimeZone(identifier: "UTC")!).first { $0.label == "EXPOSURE" } != nil)
    }

    @Test func fullInfoRowsInOrder() {
        let info = AssetInfo(
            filename: "IMG_0001.CR3", creationDate: Date(timeIntervalSince1970: 1_793_889_120), cameraName: "Canon EOS R5",
            lens: "RF35mm F1.8", focalLength: 35, fNumber: 2.8, exposureTime: 1.0 / 250, iso: 400,
            pixelWidth: 6000, pixelHeight: 4000, fileSize: 12_345_678, formats: ["RAW", "JPEG"],
            latitude: 48.8584, longitude: 2.2945)
        let rows = AssetInfoFormatter.rows(info, timeZone: TimeZone(identifier: "UTC")!)
        #expect(rows.map(\.label) == ["DATE", "CAMERA", "LENS", "EXPOSURE", "DIMENSIONS", "FILE SIZE", "FORMAT", "LOCATION", "FILENAME"])
        #expect(value("DATE", info) == "5 Nov 2026, 14:32")
        #expect(value("EXPOSURE", info) == "1/250 s · f/2.8 · ISO 400 · 35 mm")
        #expect(value("DIMENSIONS", info) == "6000 × 4000 · 24.0 MP")
        #expect(value("FILE SIZE", info) == "12.3 MB")
        #expect(value("FORMAT", info) == "RAW + JPEG")
        #expect(value("LOCATION", info) == "48.8584° N, 2.2945° E")
    }

    @Test func coordinatesAllHemispheres() {
        #expect(AssetInfoFormatter.coordinates(latitude: -33.8688, longitude: 151.2093) == "33.8688° S, 151.2093° E")
        #expect(AssetInfoFormatter.coordinates(latitude: 40.7128, longitude: -74.0060) == "40.7128° N, 74.0060° W")
        #expect(AssetInfoFormatter.coordinates(latitude: -22.9068, longitude: -43.1729) == "22.9068° S, 43.1729° W")
    }

    @Test func locationNameWins() {
        let info = AssetInfo(latitude: 1, longitude: 2, locationName: "Paris, France")
        #expect(value("LOCATION", info) == "Paris, France")
    }

    @Test func missingRowsAreOmittedExceptDate() {
        let rows = AssetInfoFormatter.rows(AssetInfo())
        #expect(rows == [AssetInfoRow(label: "DATE", value: "UNKNOWN")])
        let partial = AssetInfo(filename: "a.heic", iso: 100, formats: ["HEIC"])
        #expect(value("EXPOSURE", partial) == "ISO 100")
        #expect(value("FORMAT", partial) == "HEIC")
        #expect(value("CAMERA", partial) == nil && value("DIMENSIONS", partial) == nil && value("LOCATION", partial) == nil)
    }

    @Test func fileSizes() {
        #expect(AssetInfoFormatter.fileSize(999) == "999 B")
        #expect(AssetInfoFormatter.fileSize(1_500) == "1.5 KB")
        #expect(AssetInfoFormatter.fileSize(2_500_000_000) == "2.5 GB")
    }

    @Test func megapixels() {
        let info = AssetInfo(pixelWidth: 4032, pixelHeight: 3024)
        #expect(value("DIMENSIONS", info) == "4032 × 3024 · 12.2 MP")
    }

    @Test func formatNames() {
        #expect(AssetInfoReader.formats(of: ["public.jpeg", "com.adobe.raw-image"]) == ["RAW", "JPEG"])
        #expect(AssetInfoReader.formats(of: ["public.heic"]) == ["HEIC"])
        #expect(AssetInfoReader.formats(of: ["public.heic", "public.heic"]) == ["HEIC"])
    }
}

@Suite("Asset versions pin")
struct AssetVersionsPinTests {
    private let old = Date(timeIntervalSinceReferenceDate: 1000)
    private let new = Date(timeIntervalSinceReferenceDate: 2000)

    private func key(_ id: String, _ current: Date?, _ v: AssetVersions) -> GridThumbnailKey {
        GridThumbnailKey(id: id, pixels: 320, modificationDate: current, versions: v)
    }

    @Test func unpinnedKeyMatchesLegacyInit() {
        var v = AssetVersions()
        v.bump(["a"])
        #expect(key("a", old, v) == GridThumbnailKey(id: "a", pixels: 320, modificationDate: old, version: 1))
    }

    @Test func metadataOnlyChangeKeepsKeyStable() {
        var v = AssetVersions()
        let before = key("a", old, v)
        let summary = LibraryChangeSummary(isIncremental: true, changedIDs: ["a"], contentChangedIDs: [])
        v.apply(summary, previousModification: { _ in self.old })
        #expect(key("a", new, v) == before)
        #expect(v["a"] == 0 && v.isPinned("a"))
    }

    @Test func contentChangeBumpsAndUnpins() {
        var v = AssetVersions()
        v.pin("a", old)
        let before = key("a", new, v)
        v.apply(LibraryChangeSummary(isIncremental: true, changedIDs: ["a", "b"], contentChangedIDs: ["a"]), previousModification: { _ in self.old })
        #expect(!v.isPinned("a") && v["a"] == 1)
        #expect(key("a", new, v) != before)
        #expect(key("a", new, v).modified == new.timeIntervalSinceReferenceDate)
        #expect(v["b"] == 0 && v.isPinned("b"))
    }

    @Test func unknownContentBumpsEverything() {
        var v = AssetVersions()
        v.apply(LibraryChangeSummary(isIncremental: true, changedIDs: ["a", "b"]), previousModification: { _ in self.old })
        #expect(v["a"] == 1 && v["b"] == 1 && !v.isPinned("a"))
    }

    @Test func firstPinWins() {
        var v = AssetVersions()
        v.pin("a", old)
        v.pin("a", new)
        #expect(v.effectiveModification(for: "a", current: new) == old)
        v.unpin("a")
        #expect(v.effectiveModification(for: "a", current: new) == new)
    }

    @Test func pinnedNilDateStaysNil() {
        var v = AssetVersions()
        v.pin("a", nil)
        #expect(key("a", new, v).modified == nil)
    }

    @Test func summaryPartitions() {
        let s = LibraryChangeSummary(isIncremental: true, changedIDs: ["a", "b", "c"], contentChangedIDs: ["b"])
        #expect(s.contentIDs == ["b"] && s.metadataOnlyIDs == ["a", "c"])
        let unknown = LibraryChangeSummary(isIncremental: true, changedIDs: ["a"])
        #expect(unknown.contentIDs == ["a"] && unknown.metadataOnlyIDs.isEmpty)
    }
}

@Suite("Library errors")
struct LibraryActionErrorTests {
    @Test func userCancelDetection() {
        #expect(LibraryActions.isUserCancel(NSError(domain: NSCocoaErrorDomain, code: 3072)))
        #expect(!LibraryActions.isUserCancel(NSError(domain: NSCocoaErrorDomain, code: 1)))
        #expect(LibraryActionError.emptyTitle.errorDescription != nil)
    }
}
