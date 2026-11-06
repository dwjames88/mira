import XCTest
@testable import Mira

final class DevelopQueueTests: XCTestCase {
    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    func testAddPutsNewestFirst() {
        var q = DevelopQueue()
        XCTAssertTrue(q.add("a", at: date(1)))
        XCTAssertTrue(q.add("b", at: date(2)))
        XCTAssertTrue(q.add("c", at: date(3)))
        XCTAssertEqual(q.ids, ["c", "b", "a"])
        XCTAssertEqual(q.newestID, "c")
        XCTAssertEqual(q.count, 3)
    }

    func testReAddIsANoOpAndKeepsPlaceAndDate() {
        var q = DevelopQueue()
        q.add("a", at: date(1)); q.add("b", at: date(2))
        XCTAssertFalse(q.add("a", at: date(9)))
        XCTAssertEqual(q.ids, ["b", "a"])
        XCTAssertEqual(q.entries.last?.added, date(1))
    }

    func testRemoveClearAndRemoveAllWhere() {
        var q = DevelopQueue()
        for id in ["a", "b", "c", "d"] { q.add(id) }
        XCTAssertTrue(q.remove("b"))
        XCTAssertFalse(q.remove("zzz"))
        XCTAssertEqual(q.ids, ["d", "c", "a"])
        q.removeAll { $0.id == "c" || $0.id == "a" }
        XCTAssertEqual(q.ids, ["d"])
        q.clear()
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.newestID)
    }

    func testPruneKeepsOrderOfSurvivors() {
        var q = DevelopQueue()
        for id in ["a", "b", "c", "d"] { q.add(id) }
        XCTAssertEqual(q.prune(existing: ["a", "c", "x"]), 2)
        XCTAssertEqual(q.ids, ["c", "a"])
    }

    func testPersistenceRoundTrip() {
        let suite = "DevelopQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var q = DevelopQueue()
        q.add("a", at: date(100)); q.add("b", at: date(200))
        q.save(to: defaults, key: "k")
        XCTAssertEqual(DevelopQueue.load(from: defaults, key: "k"), q)
        XCTAssertTrue(DevelopQueue.load(from: defaults, key: "other").isEmpty)
        defaults.set(Data("junk".utf8), forKey: "bad")
        XCTAssertTrue(DevelopQueue.load(from: defaults, key: "bad").isEmpty)
    }

    @MainActor func testStorePersistsEveryChange() {
        let suite = "DevelopQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DevelopStore(defaults: defaults, key: "k")
        store.add("a"); store.add("b"); store.add("a")
        XCTAssertEqual(store.queue.ids, ["b", "a"])
        XCTAssertEqual(DevelopStore(defaults: defaults, key: "k").queue.ids, ["b", "a"])
        store.toggle("b")
        store.remove(ids: ["zzz"])
        XCTAssertEqual(DevelopStore(defaults: defaults, key: "k").queue.ids, ["a"])
        store.clear()
        XCTAssertEqual(DevelopStore(defaults: defaults, key: "k").count, 0)
    }
}
