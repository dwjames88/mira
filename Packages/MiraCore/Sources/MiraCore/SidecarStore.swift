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
/// in `<name>.<ext>.mira.json` next to it, or in a fallback folder when that is not writable.
public struct SidecarStore: Sendable {
    public let fallbackDirectory: URL

    public init(fallbackDirectory: URL) {
        self.fallbackDirectory = fallbackDirectory
    }

    /// Application Support/Mira/Sidecars (inside the container when sandboxed).
    public static func defaultFallbackDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Mira/Sidecars", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent(imageURL.lastPathComponent + ".mira.json")
    }

    /// Sidecar name used before the app was renamed from Emulsion. Read-only compatibility.
    static func legacySidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingLastPathComponent()
            .appendingPathComponent(imageURL.lastPathComponent + ".emulsion.json")
    }

    func legacyFallbackURL(for imageURL: URL) -> URL {
        let name = fallbackURL(for: imageURL).lastPathComponent
        return fallbackDirectory.appendingPathComponent(name.replacingOccurrences(of: ".mira.json", with: ".emulsion.json"))
    }

    func fallbackURL(for imageURL: URL) -> URL {
        let path = imageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return fallbackDirectory.appendingPathComponent("\(hash).mira.json")
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
              MiraAdjustment.canHandle(formatIdentifier: payload.formatIdentifier, formatVersion: payload.formatVersion)
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
        case (false, false):
            // Pre-rename (Emulsion) sidecars still count as the recipe's home until re-saved.
            let legacyAdjacent = Self.legacySidecarURL(for: imageURL)
            let legacyFallback = legacyFallbackURL(for: imageURL)
            if fm.fileExists(atPath: legacyAdjacent.path) { return .adjacent(legacyAdjacent) }
            if fm.fileExists(atPath: legacyFallback.path) { return .fallback(legacyFallback) }
            return nil
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

    /// Adjacent sidecar first, then the fallback copy; legacy (Emulsion) files only when no new
    /// one yields a recipe. Unreadable or foreign files are skipped.
    public func load(for imageURL: URL) -> Recipe? {
        let adjacent = Self.sidecarURL(for: imageURL), fallback = fallbackURL(for: imageURL)
        let ordered = location(for: imageURL)?.url == fallback ? [fallback, adjacent] : [adjacent, fallback]
        for url in ordered { if let r = Self.read(url) { return r } }
        for url in [Self.legacySidecarURL(for: imageURL), legacyFallbackURL(for: imageURL)] {
            if let r = Self.read(url) { return r }
        }
        return nil
    }

    @discardableResult
    public func save(_ recipe: Recipe, for imageURL: URL) throws -> SidecarLocation {
        let bookmark = (try? imageURL.bookmarkData(options: []))?.base64EncodedString()
        let payload = Payload(
            formatIdentifier: MiraAdjustment.formatIdentifier,
            formatVersion: MiraAdjustment.formatVersion(for: recipe),
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
            // Migrated: the legacy copies are now superseded.
            try? FileManager.default.removeItem(at: Self.legacySidecarURL(for: imageURL))
            try? FileManager.default.removeItem(at: legacyFallbackURL(for: imageURL))
            return .adjacent(adjacent)
        } catch {
            try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            let fallback = fallbackURL(for: imageURL)
            try data.write(to: fallback, options: .atomic)
            try? FileManager.default.removeItem(at: legacyFallbackURL(for: imageURL))
            return .fallback(fallback)
        }
    }

    /// Removes every sidecar (new and legacy) when present (revert to original).
    public func remove(for imageURL: URL) throws {
        let fm = FileManager.default
        var firstError: Error?
        let all = [Self.sidecarURL(for: imageURL), fallbackURL(for: imageURL),
                   Self.legacySidecarURL(for: imageURL), legacyFallbackURL(for: imageURL)]
        for url in all where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
