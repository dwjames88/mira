import MiraCore
import Photos

/// A fetch result kept so a later `PHChange` can be applied to it incrementally.
nonisolated final class FetchWatch<Object: PHObject>: @unchecked Sendable {
    private(set) var result: PHFetchResult<Object>
    init(_ result: PHFetchResult<Object>) { self.result = result }

    /// The change details for this result, nil when the change does not touch it. Moves the watch forward.
    func apply(_ change: PHChange) -> PHFetchResultChangeDetails<Object>? {
        guard let details = change.changeDetails(for: result) else { return nil }
        result = details.fetchResultAfterChanges
        return details
    }
}

/// What one library change did to the counts the gallery has shown.
nonisolated struct TrackerOutcome: Sendable, Equatable {
    /// Nodes whose pictures changed, with their new picture count: their covers and counts are stale.
    var changedCounts: [String: Int] = [:]
    /// The album tree or the shared albums list changed: the structure must be rebuilt.
    var structureChanged = false
    var isEmpty: Bool { changedCounts.isEmpty && !structureChanged }
}

/// Counts per sidebar node, fetched off the main actor and kept current from `PHChange` without refetching:
/// each counted node holds its fetch result, and a change is applied to those results (`changeDetails(for:)`),
/// so a change costs one call per tracked node instead of re-counting the whole library.
///
/// Photos delivers changes serially on a background queue and the apply runs there, so results are updated in order.
/// A scope change or a reset starts a new generation: work started under an older one is dropped.
nonisolated final class LibraryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var changeSerial = 0
    private var scope: LibraryFilter.Scope
    private var counted: [String: (watch: FetchWatch<PHAsset>, count: Int)] = [:]
    private var structure: [StructureWatch] = []

    private struct StructureWatch {
        let apply: @Sendable (PHChange) -> Bool
    }

    init(scope: LibraryFilter.Scope) { self.scope = scope }

    var currentGeneration: Int { lock.withLock { generation } }

    /// Clears everything for a new scope (or after losing access).
    func reset(scope newScope: LibraryFilter.Scope) {
        lock.withLock {
            generation += 1
            scope = newScope
            counted = [:]
            structure = []
        }
    }

    /// The node's picture count, fetching (and watching) it when not yet known. nil: dropped by a reset / cancelled.
    func count(nodeID: String) -> Int? {
        for _ in 0..<3 {
            let (known, filter, gen, serial) = lock.withLock { () -> (Int?, LibraryFilter, Int, Int) in
                var f = LibraryFilter()
                f.scope = scope
                return (counted[nodeID]?.count, f, generation, changeSerial)
            }
            if let known { return known }
            if Task.isCancelled { return nil }
            let result = SidebarLoader.fetchAssets(nodeID: nodeID, filter: filter)
            let count = result.count
            let stored = lock.withLock { () -> Bool? in
                guard gen == generation else { return nil }
                // A change landed while this was fetched: the result may predate it. Fetch again.
                if serial != changeSerial { return false }
                counted[nodeID] = (FetchWatch(result), count)
                return true
            }
            switch stored {
            case nil: return nil
            case true?: return count
            case false?: continue
            }
        }
        return nil
    }

    /// Watches the structure lists (top-level collections, folder children, shared albums) from a structure load.
    func watch(structure objects: [Unchecked<AnyObject>], generation gen: Int) {
        var watches: [StructureWatch] = []
        for box in objects {
            if let r = box.value as? PHFetchResult<PHCollection> {
                let w = FetchWatch(r)
                watches.append(StructureWatch { w.apply($0) != nil })
            } else if let r = box.value as? PHFetchResult<PHAssetCollection> {
                let w = FetchWatch(r)
                watches.append(StructureWatch { w.apply($0) != nil })
            }
        }
        lock.withLock { if gen == generation { structure = watches } }
    }

    /// Applies a change to every watched result. Called on Photos' queue.
    func process(_ change: PHChange) -> TrackerOutcome {
        lock.withLock {
            changeSerial += 1
            var outcome = TrackerOutcome()
            for (id, entry) in counted {
                if let details = entry.watch.apply(change) {
                    let after = details.fetchResultAfterChanges.count
                    counted[id] = (entry.watch, after)
                    outcome.changedCounts[id] = after
                }
            }
            for watch in structure where watch.apply(change) { outcome.structureChanged = true }
            return outcome
        }
    }
}

/// Which queued Develop photos the current scope shows. Pure so the filtering is testable; the PhotoKit lookup
/// that supplies `inScope` lives next to the Develop views.
nonisolated enum DevelopScopeFilter {
    /// Entries to show: all of them under ALL (or while the lookup has not answered), else the in-scope ones.
    static func visible(_ entries: [DevelopQueue.Entry], scope: LibraryFilter.Scope, inScope: Set<String>?) -> [DevelopQueue.Entry] {
        guard scope != .all, let inScope else { return entries }
        return entries.filter { inScope.contains($0.id) }
    }
}
