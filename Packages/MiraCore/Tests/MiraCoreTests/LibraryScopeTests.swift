import Foundation
import Testing
@testable import MiraCore

private struct LazyAlbum: CollectionNodeSource {
    var title = "Lazy"
    var identifier = "lazy"
    var isFolder = false
    var children: [any CollectionNodeSource] = []
    var assetCount = 0
    var assetCountKnown = false
}

@Suite("Library scope")
struct LibraryScopeTests {
    @Test func sharedCaseRoundTripsItsRawValue() {
        #expect(LibraryFilter.Scope.shared.rawValue == "shared")
        for scope in LibraryFilter.Scope.allCases { #expect(LibraryFilter.Scope(rawValue: scope.rawValue) == scope) }
        #expect(LibraryFilter.Scope.allCases.count == 3)
    }

    @Test func sharedCountsAsAnActiveCriterionAndARefetch() {
        var f = LibraryFilter()
        #expect(f.activeCount == 0 && f.fetchCriteria == [false, false])
        f.scope = .shared
        #expect(f.activeCount == 1)
        #expect(f.fetchCriteria == [true, false])
        f.scope = .myLibrary
        #expect(f.activeCount == 1 && f.fetchCriteria == [true, false])
        f.scope = .all
        #expect(f.activeCount == 0)
    }

    @Test func scopeMapsToSourceKinds() {
        #expect(LibraryFilter.sourceKinds(for: .myLibrary, iOS: true) == [.userLibrary])
        #expect(LibraryFilter.sourceKinds(for: .myLibrary, iOS: false) == [.userLibrary])
        #expect(LibraryFilter.sourceKinds(for: .shared, iOS: true) == [.cloudShared])
        #expect(LibraryFilter.sourceKinds(for: .shared, iOS: false) == [.cloudShared])
        #expect(LibraryFilter.sourceKinds(for: .all, iOS: true) == [.userLibrary, .cloudShared])
        // The Mac leaves ALL at PhotoKit's default, as it always did.
        #expect(LibraryFilter.sourceKinds(for: .all, iOS: false) == nil)
    }

    @Test func scopeIsPersisted() {
        let defaults = UserDefaults(suiteName: "LibraryScopeTests.\(UUID().uuidString)")!
        #expect(LibraryScopeStore.load(from: defaults) == .all)
        LibraryScopeStore.save(.shared, to: defaults)
        #expect(LibraryScopeStore.load(from: defaults) == .shared)
        defaults.set("bogus", forKey: LibraryScopeStore.key)
        #expect(LibraryScopeStore.load(from: defaults) == .all)
        #expect(LibraryScopeStore.key == "gallery.scope")
    }

    private var sections: [SidebarSection] {
        let n = { (id: String) in SidebarNode(id: id, title: id, kind: .album, count: 1) }
        return SidebarModel.sections(library: [SidebarNode(id: "all", title: "Library", kind: .library, count: 3)],
                                     albums: [n("a")], shared: [n("s")], mediaTypes: [n("m")], utilities: [n("u")])
    }

    @Test func sectionsPerScope() {
        #expect(SidebarModel.applying(scope: .all, to: sections).map(\.id) == ["library", "albums", "shared", "media", "utilities"])
        #expect(SidebarModel.applying(scope: .myLibrary, to: sections).map(\.id) == ["library", "albums", "media", "utilities"])
        #expect(SidebarModel.applying(scope: .shared, to: sections).map(\.id) == ["library", "shared"])
    }

    @Test func albumsWithoutACountHaveNoCountYet() {
        let nodes = SidebarModel.albumNodes(from: [LazyAlbum()])
        #expect(nodes.first?.count == nil)
        #expect(SidebarModel.visible(nodes).count == 1)
    }
}
