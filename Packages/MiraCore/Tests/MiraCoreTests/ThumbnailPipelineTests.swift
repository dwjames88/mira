import Foundation
import Testing
@testable import MiraCore

private final class FakeImage {
    let name: String
    init(_ name: String) { self.name = name }
}

/// A grid of cells over a fake image manager: the same code paths the Mac and iOS grids use
/// (`ThumbnailPipeline`, `ThumbnailCellLoader`, `AssetVersions`), without PhotoKit.
@MainActor
private final class FakeGrid {
    typealias Pipeline = ThumbnailPipeline<FakeImage, String>
    let metrics = ThumbnailMetrics()
    var requested: [String] = []
    var ids: [String]
    var versions = AssetVersions()
    var modified: [String: Date] = [:]
    var cells: [Int: ThumbnailCellLoader<FakeImage, String>] = [:]
    var visible: Range<Int>
    private(set) var pipeline: Pipeline!

    init(count: Int, visible: Range<Int>) {
        ids = (0..<count).map { "A\($0)" }
        self.visible = visible
        pipeline = Pipeline(metrics: metrics, fetch: { [unowned self] asset, key, deliver in
            self.requested.append(asset)
            deliver(FakeImage("\(key.id)#\(key.version)"), false)
            return self.requested.count
        }, cancel: { _ in })
    }

    func key(at index: Int) -> GridThumbnailKey {
        let id = ids[index]
        return GridThumbnailKey(id: id, pixels: 320, modificationDate: modified[id], version: versions[id])
    }

    /// Every visible cell runs its update, as `onAppear` / `onChange` would.
    func refreshVisible() {
        for index in visible where index < ids.count {
            let loader = cells[index] ?? ThumbnailCellLoader()
            cells[index] = loader
            loader.update(key(at: index), asset: ids[index], pipeline: pipeline)
        }
    }

    /// The grid after the PhotoKit change: remove, insert, bump the changed ones.
    func apply(removed: [Int] = [], inserted: [(Int, String)] = [], changed: [String] = []) {
        for index in removed.sorted(by: >) { ids.remove(at: index) }
        for (index, id) in inserted.sorted(by: { $0.0 < $1.0 }) { ids.insert(id, at: index) }
        versions.bump(changed)
        refreshVisible()
    }
}

@MainActor
@Suite struct ThumbnailPipelineTests {
    @Test func firstShowRequestsEachVisibleCellOnce() {
        let grid = FakeGrid(count: 100, visible: 0..<20)
        grid.refreshVisible()
        grid.refreshVisible()
        #expect(grid.metrics.snapshot.requests == 20)
        #expect(grid.cells[3]?.image?.name == "A3#0")
    }

    /// Exit-editor: the grid stays mounted and every cell is asked again (appear/onChange). All hits.
    @Test func exitingTheEditorRequestsNothingForUnchangedAssets() {
        let grid = FakeGrid(count: 100, visible: 40..<60)
        grid.refreshVisible()
        let before = grid.metrics.snapshot
        // Editor open, editor closed: even if the view is rebuilt with fresh cell state, the cache answers.
        grid.cells = [:]
        grid.refreshVisible()
        let after = grid.metrics.snapshot
        #expect(after.requests == before.requests)
        #expect(after.cacheHits - before.cacheHits == 20)
        #expect(after.stopAllCalls == 0)
        #expect(grid.visible == 40..<60)
        #expect(grid.cells[45]?.image?.name == "A45#0")
    }

    @Test func editingOneAssetRequestsOnlyThatAsset() {
        let grid = FakeGrid(count: 100, visible: 0..<20)
        grid.refreshVisible()
        let before = grid.metrics.snapshot.requests
        grid.requested = []
        grid.apply(changed: ["A7"])
        #expect(grid.metrics.snapshot.requests - before == 1)
        #expect(grid.requested == ["A7"])
        #expect(grid.cells[7]?.image?.name == "A7#1")
        #expect(grid.cells[8]?.image?.name == "A8#0")
    }

    @Test func modificationDateChangeMissesTheCache() {
        let grid = FakeGrid(count: 10, visible: 0..<3)
        grid.refreshVisible()
        grid.requested = []
        grid.modified["A1"] = Date(timeIntervalSinceReferenceDate: 1_000)
        grid.refreshVisible()
        #expect(grid.requested == ["A1"])
    }

    @Test func insertionRequestsOnlyTheInsertedVisibleCells() {
        let grid = FakeGrid(count: 100, visible: 0..<20)
        grid.refreshVisible()
        grid.requested = []
        grid.apply(inserted: [(5, "NEW1"), (6, "NEW2")])
        #expect(grid.requested.sorted() == ["NEW1", "NEW2"])
        // Shifted cells now show other assets, all from the cache.
        #expect(grid.cells[7]?.image?.name == "A5#0")
        #expect(grid.metrics.snapshot.requests == 22)
    }

    @Test func insertionOutsideTheVisibleWindowRequestsNothing() {
        let grid = FakeGrid(count: 100, visible: 0..<20)
        grid.refreshVisible()
        grid.requested = []
        grid.apply(inserted: [(80, "FAR")])
        #expect(grid.requested.isEmpty)
    }

    @Test func removalRequestsNothingForSurvivors() {
        let grid = FakeGrid(count: 100, visible: 0..<20)
        grid.refreshVisible()
        grid.requested = []
        grid.apply(removed: [3])
        // Only the asset that slid into the window (A20, never loaded) is requested.
        #expect(grid.requested == ["A20"])
        #expect(grid.cells[3]?.image?.name == "A4#0")
    }

    @Test func degradedImageIsShownButNotRemembered() {
        let metrics = ThumbnailMetrics()
        var finals: [ThumbnailPipeline<FakeImage, String>.Deliver] = []
        let pipeline = ThumbnailPipeline<FakeImage, String>(metrics: metrics, fetch: { _, _, deliver in
            finals.append(deliver)
            return 1
        }, cancel: { _ in })
        let loader = ThumbnailCellLoader<FakeImage, String>()
        let key = GridThumbnailKey(id: "X", pixels: 64, modificationDate: nil)
        loader.update(key, asset: "X", pipeline: pipeline)
        finals[0](FakeImage("low"), true)
        #expect(loader.image?.name == "low")
        #expect(pipeline.cached(key) == nil)
        // A second update while the final is pending sends nothing.
        loader.update(key, asset: "X", pipeline: pipeline)
        #expect(metrics.snapshot.requests == 1)
        finals[0](FakeImage("final"), false)
        #expect(pipeline.cached(key)?.name == "final")
        loader.update(key, asset: "X", pipeline: pipeline)
        #expect(metrics.snapshot.requests == 1)
    }

    @Test func cellKeepsItsImageWhileAnEditedAssetReloadsButClearsForAnotherAsset() {
        var pending: ThumbnailPipeline<FakeImage, String>.Deliver?
        let pipeline = ThumbnailPipeline<FakeImage, String>(metrics: ThumbnailMetrics(), fetch: { _, _, deliver in
            pending = deliver
            return 1
        }, cancel: { _ in })
        let loader = ThumbnailCellLoader<FakeImage, String>()
        loader.update(GridThumbnailKey(id: "X", pixels: 64, modificationDate: nil), asset: "X", pipeline: pipeline)
        pending?(FakeImage("v0"), false)
        loader.update(GridThumbnailKey(id: "X", pixels: 64, modificationDate: nil, version: 1), asset: "X", pipeline: pipeline)
        #expect(loader.image?.name == "v0")
        loader.update(GridThumbnailKey(id: "Y", pixels: 64, modificationDate: nil), asset: "Y", pipeline: pipeline)
        #expect(loader.image == nil)
    }

    @Test func changeSummary() {
        #expect(LibraryChangeSummary(isIncremental: true, changedIDs: ["a"]).membershipChanged == false)
        #expect(LibraryChangeSummary(isIncremental: true, insertedCount: 1).membershipChanged)
        #expect(LibraryChangeSummary(isIncremental: true, removedCount: 1).membershipChanged)
        #expect(LibraryChangeSummary(isIncremental: true, hasMoves: true).membershipChanged)
        #expect(LibraryChangeSummary(isIncremental: false).membershipChanged)
    }

    @Test func metricsCountPreheatAndStops() {
        let m = ThumbnailMetrics()
        m.recordPreheat(assets: 30); m.recordStop(); m.recordStopAll()
        #expect(m.snapshot.assetsPreheated == 30 && m.snapshot.stopCalls == 1 && m.snapshot.stopAllCalls == 1)
        m.reset()
        #expect(m.snapshot == ThumbnailMetrics.Snapshot())
    }

    @Test func indexRemapShiftsAndDrops() {
        // Old fetch 0...9; remove 2 and 5; two photos inserted at final positions 0 and 4.
        #expect(IndexRemap.apply([1, 2, 5, 8], removed: [2, 5], inserted: []) == [1, 6])
        #expect(IndexRemap.apply([1, 3, 8], removed: [], inserted: [0, 4]) == [2, 5, 10])
        #expect(IndexRemap.apply([0, 1, 2], removed: [1], inserted: [0]) == [1, 2])
    }
}
