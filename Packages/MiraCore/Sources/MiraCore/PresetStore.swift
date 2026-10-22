import Foundation

public enum PresetError: Error, Equatable, Sendable {
    case emptyNickname
    case notFound
    case writeFailed(String)
}

/// The saved presets, kept in one JSON file shared by the Mira app and its Photos extension.
///
/// File: `{"version":1,"presets":[...]}` in `Presets.json`, inside the App Group container
/// (`<container>/Library/Application Support/Mira/`), or the process's own Application Support
/// folder when the group is unavailable. Both processes use the same file; each store notices the
/// other's writes by the file's modification date and reloads (`reloadIfChanged()`, called on every
/// read and before every change).
@MainActor
public final class PresetStore {
    public nonisolated static let groupIdentifier = "VF945J28YU.com.fieldframes.mira"
    public nonisolated static let fileName = "Presets.json"
    nonisolated static let fileVersion = 1

    /// The store the app and the extension use.
    public static let shared = PresetStore(directory: defaultDirectory())

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var backupURL: URL { directory.appendingPathComponent(Self.fileName + ".bak") }

    private var items: [Preset] = []
    private var stamp: Stamp?
    private var loadedOnce = false

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Location

    /// Where the shared file lives: the App Group container's Application Support/Mira, else this
    /// process's own Application Support/Mira.
    public nonisolated static func defaultDirectory(
        fileManager: FileManager = .default, groupIdentifier: String = PresetStore.groupIdentifier
    ) -> URL {
        directory(groupContainer: fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier),
                  fileManager: fileManager)
    }

    /// The pure part of `defaultDirectory`: a group container wins; nil falls back.
    public nonisolated static func directory(groupContainer: URL?, fileManager: FileManager = .default) -> URL {
        if let groupContainer {
            return groupContainer.appendingPathComponent("Library/Application Support/Mira", isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Mira", isDirectory: true)
    }

    // MARK: Reading

    /// Every preset, oldest first. Picks up changes made by the other process first.
    public var all: [Preset] {
        reloadIfChanged()
        return items
    }

    public func preset(id: UUID) -> Preset? {
        reloadIfChanged()
        return items.first { $0.id == id }
    }

    /// Reloads when the file changed on disk since it was last read or written. True if it did.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        let current = currentStamp()
        if loadedOnce, current == stamp { return false }
        load(current)
        return true
    }

    private func currentStamp() -> Stamp? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        return Stamp(modified: date, size: values.fileSize ?? 0)
    }

    private func load(_ current: Stamp?) {
        loadedOnce = true
        stamp = current
        guard current != nil, let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        do {
            items = try Self.decode(data)
        } catch {
            // Keep what was there, start empty; the damaged file is replaced on the next save.
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            items = []
        }
    }

    // MARK: Changing

    @discardableResult
    public func add(_ preset: Preset) throws -> Preset {
        var p = preset
        p.nickname = try Self.validated(p.nickname)
        reloadIfChanged()
        var next = items
        next.removeAll { $0.id == p.id }
        next.append(p)
        try commit(next)
        return p
    }

    /// Saves a new preset from the current look.
    @discardableResult
    public func add(nickname: String, recipe: Recipe, filmName: String?) throws -> Preset {
        try add(Preset(nickname: nickname, recipe: recipe, filmName: filmName))
    }

    /// Changes the nickname only; the film and develop settings stay.
    @discardableResult
    public func rename(id: UUID, nickname: String) throws -> Preset {
        let name = try Self.validated(nickname)
        reloadIfChanged()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        var next = items
        next[index].nickname = name
        next[index].modified = Preset.millisecond(Date())
        try commit(next)
        return next[index]
    }

    /// A copy with a new id and " copy" after the nickname, placed right after the original.
    @discardableResult
    public func duplicate(id: UUID) throws -> Preset {
        reloadIfChanged()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        var copy = items[index]
        let now = Preset.millisecond(Date())
        copy.id = UUID()
        copy.nickname += " copy"
        copy.created = now
        copy.modified = now
        var next = items
        next.insert(copy, at: index + 1)
        try commit(next)
        return copy
    }

    public func delete(id: UUID) throws {
        reloadIfChanged()
        guard items.contains(where: { $0.id == id }) else { throw PresetError.notFound }
        try commit(items.filter { $0.id != id })
    }

    /// The nickname trimmed, or `emptyNickname`.
    public nonisolated static func validated(_ nickname: String) throws -> String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetError.emptyNickname }
        return trimmed
    }

    // MARK: File

    private func commit(_ next: [Preset]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(next).write(to: fileURL, options: .atomic)
        } catch {
            throw PresetError.writeFailed(error.localizedDescription)
        }
        items = next
        stamp = currentStamp()
        loadedOnce = true
    }

    private struct FileModel: Codable {
        var version: Int
        var presets: [Preset]
    }

    /// Decodes entry by entry, so one unreadable preset does not hide the rest.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct LossyFile: Decodable {
        var presets: [Lossy<Preset>]?
    }

    nonisolated static func decode(_ data: Data) throws -> [Preset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date"))
        }
        let file = try decoder.decode(LossyFile.self, from: data)
        return (file.presets ?? []).compactMap(\.value)
    }

    nonisolated static func encode(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, e in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = e.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return try encoder.encode(FileModel(version: fileVersion, presets: presets))
    }
}
