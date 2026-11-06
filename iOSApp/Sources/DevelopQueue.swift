import Foundation
import Observation

/// The DEVELOP queue: photo local identifiers waiting to be developed, newest first. Pure value type (no PhotoKit),
/// persisted as one small JSON blob in UserDefaults.
///
/// Re-adding an identifier that is already queued is a no-op: it keeps its place and original date, so the
/// double adds the camera can produce (a retried print, a manual add of a frame just shot) never shuffle the grid.
struct DevelopQueue: Equatable, Codable, Sendable {
    struct Entry: Equatable, Codable, Sendable {
        var id: String
        var added: Date
    }

    /// Newest first.
    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) { self.entries = entries }

    var ids: [String] { entries.map(\.id) }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var newestID: String? { entries.first?.id }

    func contains(_ id: String) -> Bool { entries.contains { $0.id == id } }

    /// Puts `id` at the top. Returns false (and changes nothing) when it is already queued.
    @discardableResult
    mutating func add(_ id: String, at date: Date = Date()) -> Bool {
        guard !contains(id) else { return false }
        entries.insert(Entry(id: id, added: date), at: 0)
        return true
    }

    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count != before
    }

    mutating func clear() { entries.removeAll() }

    mutating func removeAll(where shouldRemove: (Entry) -> Bool) { entries.removeAll(where: shouldRemove) }

    /// Drops identifiers whose assets no longer exist. Returns how many were dropped.
    @discardableResult
    mutating func prune(existing: Set<String>) -> Int {
        let before = entries.count
        entries.removeAll { !existing.contains($0.id) }
        return before - entries.count
    }

    // MARK: Persistence

    static let defaultsKey = "develop.queue.v1"

    /// The saved queue; empty when nothing was saved or the blob is unreadable.
    static func load(from defaults: UserDefaults = .standard, key: String = defaultsKey) -> DevelopQueue {
        guard let data = defaults.data(forKey: key),
              let queue = try? decoder.decode(DevelopQueue.self, from: data) else { return DevelopQueue() }
        return queue
    }

    func save(to defaults: UserDefaults = .standard, key: String = defaultsKey) {
        if let data = try? Self.encoder.encode(self) { defaults.set(data, forKey: key) }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The app-wide DEVELOP queue: observable, persisted on every change.
@MainActor @Observable
final class DevelopStore {
    static let shared = DevelopStore()

    private(set) var queue: DevelopQueue
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(defaults: UserDefaults = .standard, key: String = DevelopQueue.defaultsKey) {
        self.defaults = defaults
        self.key = key
        queue = DevelopQueue.load(from: defaults, key: key)
    }

    var count: Int { queue.count }
    func contains(_ id: String) -> Bool { queue.contains(id) }

    func add(_ id: String) { mutate { $0.add(id) } }
    func remove(_ id: String) { mutate { $0.remove(id) } }
    func clear() { mutate { $0.clear() } }
    func remove(ids: Set<String>) { mutate { $0.removeAll { ids.contains($0.id) } } }
    func toggle(_ id: String) { contains(id) ? remove(id) : add(id) }

    /// Drops queued items whose assets were deleted. Only with full access: a limited selection hides
    /// assets that still exist.
    func pruneMissing(fullAccess: Bool) async {
        guard fullAccess, !queue.isEmpty else { return }
        let ids = queue.ids
        let existing = await Task.detached(priority: .utility) { Self.existingIdentifiers(among: ids) }.value
        mutate { $0.prune(existing: existing) }
    }

    private func mutate(_ change: (inout DevelopQueue) -> Void) {
        var next = queue
        change(&next)
        guard next != queue else { return }
        queue = next
        next.save(to: defaults, key: key)
    }
}
