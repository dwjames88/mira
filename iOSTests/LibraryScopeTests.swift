import MiraCore
import Photos
import XCTest
@testable import Mira

/// The iPhone gallery's library scope and the count cache behind the album list. Pure logic only: nothing here
/// reads the Photos library.
@MainActor
final class LibraryScopeTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "LibraryScopeTests.\(UUID().uuidString)")! }

    // MARK: scope -> PhotoKit source types

    func testScopeMapsToSourceTypes() {
        XCTAssertEqual(SidebarLoader.sourceTypes(for: .myLibrary), [.typeUserLibrary])
        XCTAssertEqual(SidebarLoader.sourceTypes(for: .shared), [.typeCloudShared])
        XCTAssertEqual(SidebarLoader.sourceTypes(for: .all), [.typeUserLibrary, .typeCloudShared])
    }

    func testImageOptionsCarryTheScope() {
        var filter = LibraryFilter()
        filter.scope = .shared
        XCTAssertEqual(SidebarLoader.imageOptions(filter: filter).includeAssetSourceTypes, [.typeCloudShared])
        filter.scope = .myLibrary
        XCTAssertEqual(SidebarLoader.imageOptions(filter: filter).includeAssetSourceTypes, [.typeUserLibrary])
    }

    // MARK: persistence

    func testScopeIsRestoredAndSaved() {
        let d = defaults()
        XCTAssertEqual(GalleryModel(defaults: d).scope, .all, "default is ALL")
        LibraryScopeStore.save(.myLibrary, to: d)
        XCTAssertEqual(GalleryModel(defaults: d).scope, .myLibrary)
        let model = GalleryModel(defaults: d)
        model.scope = .shared
        XCTAssertEqual(LibraryScopeStore.load(from: d), .shared)
        XCTAssertEqual(d.string(forKey: "gallery.scope"), "shared")
    }

    func testChangingScopeClearsTheCachesAndMovesTheCoverEpoch() {
        let model = GalleryModel(defaults: defaults())
        model.publish(counts: ["a": 3, "b": 0])
        let token = model.coverToken(for: "a")
        model.scope = .myLibrary
        XCTAssertTrue(model.counts.isEmpty)
        XCTAssertTrue(model.emptyIDs.isEmpty)
        XCTAssertNotEqual(model.coverToken(for: "a"), token)
    }

    // MARK: count cache

    func testZeroCountsHideANodeAndALaterCountShowsItAgain() {
        let model = GalleryModel(defaults: defaults())
        let a = SidebarNode(id: "a", title: "A", kind: .album), b = SidebarNode(id: "b", title: "B", kind: .album)
        XCTAssertEqual(model.visible([a, b]).count, 2, "unknown counts are shown")
        model.publish(counts: ["a": 0, "b": 4])
        XCTAssertEqual(model.visible([a, b]).map(\.id), ["b"])
        XCTAssertEqual(model.count(of: b), 4)
        model.publish(counts: ["a": 2])
        XCTAssertEqual(model.visible([a, b]).map(\.id), ["a", "b"])
    }

    func testCoverTokenMovesOnlyForTheNodeThatChanged() {
        let model = GalleryModel(defaults: defaults())
        let a = model.coverToken(for: "a"), b = model.coverToken(for: "b")
        model.invalidateCover(nodeID: "a")
        XCTAssertNotEqual(model.coverToken(for: "a"), a)
        XCTAssertEqual(model.coverToken(for: "b"), b)
    }

    // MARK: DEVELOP

    func testDevelopShowsOnlyInScopeEntriesButTheStoreKeepsTheRest() {
        let entries = [DevelopQueue.Entry(id: "p", added: .now), DevelopQueue.Entry(id: "s", added: .now)]
        XCTAssertEqual(DevelopScopeFilter.visible(entries, scope: .all, inScope: ["p"]).count, 2)
        XCTAssertEqual(DevelopScopeFilter.visible(entries, scope: .shared, inScope: ["s"]).map(\.id), ["s"])
        XCTAssertEqual(DevelopScopeFilter.visible(entries, scope: .myLibrary, inScope: nil).count, 2, "until the lookup answers")
        // Out of scope is not missing: the prune keeps every entry Photos still has, in any source.
        var queue = DevelopQueue(entries: entries)
        XCTAssertEqual(queue.prune(existing: ["p", "s"], checked: ["p", "s"]), 0)
        XCTAssertEqual(queue.count, 2)
    }

    func testTheExistenceCheckLooksAcrossEverySource() {
        let o = DevelopStore.allSourcesOptions()
        XCTAssertEqual(o.includeAssetSourceTypes, [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced])
        XCTAssertTrue(o.includeHiddenAssets)
    }

    func testScopeCopy() {
        XCTAssertEqual(LibraryScopeCopy.options.map(\.title), ["PERSONAL", "SHARED", "ALL"])
        XCTAssertEqual(LibraryScopeCopy.hint(for: .myLibrary), "WITHOUT SHARED ALBUMS")
        XCTAssertEqual(LibraryScopeCopy.hint(for: .shared), "SHARED ALBUMS ONLY")
        XCTAssertNil(LibraryScopeCopy.hint(for: .all))
    }
}
