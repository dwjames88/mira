import Foundation
import Testing
@testable import MiraCore

private struct Fake: CollectionNodeSource {
    var title: String
    var identifier: String
    var isFolder: Bool = false
    var children: [any CollectionNodeSource] = []
    var assetCount: Int = 0

    static func album(_ title: String, _ count: Int = 1) -> Fake { Fake(title: title, identifier: "a:\(title)", assetCount: count) }
    static func folder(_ title: String, _ children: [Fake]) -> Fake {
        Fake(title: title, identifier: "f:\(title)", isFolder: true, children: children)
    }
}

@Suite("Sidebar model")
struct SidebarModelTests {
    private func tree() -> [SidebarNode] {
        SidebarModel.albumNodes(from: [
            Fake.album("zebra"),
            Fake.folder("Trips", [
                Fake.folder("2021", [Fake.album("West Coast", 12), Fake.folder("Empty inner", [])]),
                Fake.album("Album 10"), Fake.album("album 2"),
            ]),
            Fake.folder("Nothing", [Fake.folder("Still nothing", [])]),
            Fake.album("Apple"),
        ])
    }

    @Test func ordersFoldersAndAlbumsTogetherByStandardCompare() {
        let top = tree().map(\.title)
        #expect(top == ["Apple", "Trips", "zebra"])
        let trips = tree()[1].children.map(\.title)
        #expect(trips == ["2021", "album 2", "Album 10"])
    }

    @Test func prunesEmptyFoldersAtAnyDepth() {
        let top = tree()
        #expect(!top.contains { $0.title == "Nothing" })
        let year = top[1].children[0]
        #expect(year.children.map(\.title) == ["West Coast"])
    }

    @Test func keepsDepthAndCounts() {
        let leaf = tree()[1].children[0].children[0]
        #expect(leaf.kind == .album)
        #expect(leaf.count == 12)
        #expect(tree()[1].count == nil)
        #expect(tree()[1].kind == .folder)
    }

    @Test func hidesEmptySectionsAndZeroCountEntries() {
        let lib = [SidebarNode(id: "all", title: "Library", kind: .library, count: 5)]
        let sections = SidebarModel.sections(
            library: lib, albums: [], shared: [],
            mediaTypes: [SidebarNode(id: "smart:202", title: "Videos", kind: .smart(202), count: 0),
                         SidebarNode(id: "smart:211", title: "Screenshots", kind: .smart(211), count: 3)],
            utilities: [SidebarNode(id: "smart:205", title: "Hidden", kind: .smart(205), count: 0)])
        #expect(sections.map(\.id) == ["library", "media"])
        #expect(sections[1].nodes.map(\.title) == ["Screenshots"])
    }

    @Test func sectionOrder() {
        let n = { (id: String) in SidebarNode(id: id, title: id, kind: .album, count: 1) }
        let sections = SidebarModel.sections(library: [n("l")], albums: [n("a")], shared: [n("s")],
                                             mediaTypes: [n("m")], utilities: [n("u")])
        #expect(sections.map(\.title) == ["Library", "Albums", "Shared Albums", "Media Types", "Utilities"])
    }

    @Test func breadcrumbAndAncestors() {
        let sections = [SidebarSection(id: "albums", title: "Albums", nodes: tree())]
        #expect(SidebarModel.breadcrumb(to: "a:West Coast", in: sections) == ["Trips", "2021", "West Coast"])
        #expect(SidebarModel.breadcrumb(to: "a:Apple", in: sections) == ["Apple"])
        #expect(SidebarModel.breadcrumb(to: "missing", in: sections) == nil)
        #expect(SidebarModel.ancestorIDs(of: "a:West Coast", in: sections) == ["f:Trips", "f:2021"])
        #expect(SidebarModel.node(withID: "f:2021", in: sections)?.kind == .folder)
    }

    @Test func visibleRowsFollowExpansion() {
        let section = SidebarSection(id: "albums", title: "Albums", nodes: tree())
        #expect(SidebarModel.visibleRows(in: section, expanded: []).map(\.node.title) == ["Apple", "Trips", "zebra"])
        let rows = SidebarModel.visibleRows(in: section, expanded: ["f:Trips", "f:2021"])
        #expect(rows.map(\.node.title) == ["Apple", "Trips", "2021", "West Coast", "album 2", "Album 10", "zebra"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 1, 1, 0])
    }

    @Test func extractsRatingAlbumsInOrderIncludingNested() {
        let albums = SidebarModel.albumNodes(from: [
            Fake.album("\u{2605}\u{2605}"), Fake.album("Rejected"), Fake.album("\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}"),
            Fake.album("flagged"), Fake.album("\u{2605}"), Fake.album("\u{2605} Trips"), Fake.album("Normal"),
            Fake.folder("Old", [Fake.album(" \u{2605}\u{2605}\u{2605} ")]),
            Fake.folder("Keep", [Fake.album("Inside"), Fake.album("Picks")]),
        ])
        let (ratings, rest) = SidebarModel.extractRatings(from: albums)
        #expect(ratings.map(\.title) == ["\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}", " \u{2605}\u{2605}\u{2605} ", "\u{2605}\u{2605}", "\u{2605}", "flagged", "Picks", "Rejected"])
        #expect(rest.map(\.title) == ["\u{2605} Trips", "Keep", "Normal"])
        #expect(rest[1].children.map(\.title) == ["Inside"])
    }

    @Test func ratingTitleMatching() {
        #expect(SidebarModel.ratingRank(forTitle: "\u{2B50}\u{2B50}") == 2)
        #expect(SidebarModel.ratingRank(forTitle: "\u{2606}") == 1)
        #expect(SidebarModel.ratingRank(forTitle: "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}") == nil)
        #expect(SidebarModel.ratingRank(forTitle: "Rejects") == -1)
        #expect(SidebarModel.ratingRank(forTitle: "Pick") == 0)
        #expect(SidebarModel.ratingRank(forTitle: "Picks 2021") == nil)
    }

    @Test func starsSectionFollowsLibraryAndHidesEmpties() {
        let n = { (id: String, c: Int) in SidebarNode(id: id, title: id, kind: .album, count: c) }
        let sections = SidebarModel.sections(library: [n("l", 1)], stars: [n("s5", 2), n("s1", 0)], albums: [n("a", 1)],
                                             shared: [], mediaTypes: [], utilities: [])
        #expect(sections.map(\.id) == ["library", "stars", "albums"])
        #expect(sections[1].nodes.map(\.id) == ["s5"])
    }
}
