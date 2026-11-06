import Foundation
import Testing
@testable import MiraCore

private let grid = ["a", "b", "c", "d", "e"]

@Suite("Library interaction")
struct LibraryInteractionTests {
    @Test func plainClickReplacesSelection() {
        var s = LibrarySelection()
        s.toggle("a"); s.toggle("b")
        let on = LibraryInteraction.click(&s, id: "d", modifiers: [])
        #expect(on && s.ids == ["d"] && s.anchor == "d")
    }

    @Test func commandClickTogglesAndReportsState() {
        var s = LibrarySelection()
        LibraryInteraction.click(&s, id: "a", modifiers: [])
        #expect(LibraryInteraction.click(&s, id: "c", modifiers: .command))
        #expect(s.ids == ["a", "c"])
        #expect(!LibraryInteraction.click(&s, id: "c", modifiers: .command))
        #expect(s.ids == ["a"])
    }

    @Test func shiftClickExtendsFromAnchor() {
        var s = LibrarySelection()
        LibraryInteraction.click(&s, id: "b", modifiers: [])
        LibraryInteraction.click(&s, id: "d", modifiers: .shift) { grid }
        #expect(s.ids == ["b", "c", "d"])
    }

    @Test func shiftClickWithoutAnchorSelectsOne() {
        var s = LibrarySelection()
        LibraryInteraction.click(&s, id: "c", modifiers: .shift) { grid }
        #expect(s.ids == ["c"])
    }

    @Test func shiftClickOutsideRangeFallsBackToPlain() {
        var s = LibrarySelection()
        LibraryInteraction.click(&s, id: "a", modifiers: [])
        LibraryInteraction.click(&s, id: "zzz", modifiers: .shift) { grid }
        #expect(s.ids == ["zzz"])
    }

    @Test func actionIDsUseSelectionOnlyWhenClickedIsInIt() {
        var s = LibrarySelection()
        s.toggle("a"); s.toggle("c")
        #expect(LibraryInteraction.actionIDs(clicked: "c", selection: s) == ["a", "c"])
        #expect(LibraryInteraction.actionIDs(clicked: "e", selection: s) == ["e"])
        #expect(LibraryInteraction.dragIDs(dragged: "a", selection: s) == ["a", "c"])
        #expect(LibraryInteraction.dragIDs(dragged: "b", selection: LibrarySelection()) == ["b"])
    }

    @Test func dragPayloadRoundTrips() {
        let ids = ["AAA/L0/001", "BBB/L0/001"]
        #expect(LibraryDragPayload.decode(LibraryDragPayload.encode(ids)) == ids)
    }

    @Test func dragPayloadRejectsForeignAndEmpty() {
        #expect(LibraryDragPayload.decode("hello") == nil)
        #expect(LibraryDragPayload.decode(LibraryDragPayload.prefix) == nil)
        #expect(LibraryDragPayload.decode(LibraryDragPayload.prefix + "a\n\na\n b ") == ["a", "b"])
    }
}
