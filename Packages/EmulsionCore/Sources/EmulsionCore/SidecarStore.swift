import CryptoKit
import Foundation

public enum SidecarLocation: Equatable, Sendable {
    case adjacent(URL)
    case fallback(URL)

    public var url: URL {
        switch self {
        case .adjacent(let u), .fallback(let u): u
        }
    }
}

/// Stores recipes for files opened from disk. The original is never modified: the recipe goes
/// in `<name>.<ext>.emulsion.json` next to it, or in a fallback folder when that is not writable.
public struct SidecarStore: Sendable {
    public let fallbackDirectory: URL

    public init(fallbackDirectory: URL) {
        self.fallbackDirectory = fallbackDirectory
    }

    /// Application Support/Emulsion/Sidecars (inside the container when sandboxed).
    public static func defaultFallbackDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Emulsion/Sidecars", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent(imageURL.lastPathComponent + ".emulsion.json")
    }

    func fallbackURL(for imageURL: URL) -> URL {
        let path = imageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return fallbackDirectory.appendingPathComponent("\(hash).emulsion.json")
    }

    // MARK: File payload

    private struct Payload: Codable {
        var formatIdentifier: String
        var formatVersion: String
        var recipe: Recipe
        var sourcePath: String?
        var bookmark: String?
        var modified: String?
    }

    private static func read(_ url: URL) -> Recipe? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              EmulsionAdjustment.canHandle(formatIdentifier: payload.formatIdentifier, formatVersion: payload.formatVersion)
        else { return nil }
        return payload.recipe
    }

    // MARK: API

    public func location(for imageURL: URL) -> SidecarLocation? {
        let fm = FileManager.default
        let adjacent = Self.sidecarURL(for: imageURL)
        let fallback = fallbackURL(for: imageURL)
        let hasAdjacent = fm.fileExists(atPath: adjacent.path)
        let hasFallback = fm.fileExists(atPath: fallback.path)
        switch (hasAdjacent, hasFallback) {
        case (false, false): return nil
        case (true, false): return .adjacent(adjacent)
        case (false, true): return .fallback(fallback)
        case (true, true):
            // The fallback is only written when the adjacent write failed, so the newer one wins.
            return Self.modified(fallback) > Self.modified(adjacent) ? .fallback(fallback) : .adjacent(adjacent)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Adjacent sidecar first, then the fallback copy. Unreadable or foreign files are skipped.
    public func load(for imageURL: URL) -> Recipe? {
        let adjacent = Self.sidecarURL(for: imageURL), fallback = fallbackURL(for: imageURL)
        let ordered = location(for: imageURL)?.url == fallback ? [fallback, adjacent] : [adjacent, fallback]
        for url in ordered { if let r = Self.read(url) { return r } }
        return nil
    }

    @discardableResult
    public func save(_ recipe: Recipe, for imageURL: URL) throws -> SidecarLocation {
        let bookmark = (try? imageURL.bookmarkData(options: []))?.base64EncodedString()
        let payload = Payload(
            formatIdentifier: EmulsionAdjustment.formatIdentifier,
            formatVersion: EmulsionAdjustment.formatVersion,
            recipe: recipe,
            sourcePath: imageURL.standardizedFileURL.path,
            bookmark: bookmark,
            modified: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(payload)

        let adjacent = Self.sidecarURL(for: imageURL)
        do {
            try data.write(to: adjacent, options: .atomic)
            // A stale fallback copy would otherwise shadow nothing, but remove it to avoid confusion.
            try? FileManager.default.removeItem(at: fallbackURL(for: imageURL))
            return .adjacent(adjacent)
        } catch {
            try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            let fallback = fallbackURL(for: imageURL)
            try data.write(to: fallback, options: .atomic)
            return .fallback(fallback)
        }
    }

    /// Removes both sidecars when present (revert to original).
    public func remove(for imageURL: URL) throws {
        let fm = FileManager.default
        var firstError: Error?
        for url in [Self.sidecarURL(for: imageURL), fallbackURL(for: imageURL)] where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
