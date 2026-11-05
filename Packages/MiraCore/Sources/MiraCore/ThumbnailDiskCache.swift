import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bump when anything that changes how a film-strip thumbnail looks changes: the grading graph, the
/// film LUT decoding, the output colour space, or the thumbnail encoding. Old files are then simply
/// never asked for again and age out of the cache.
public enum ThumbnailCacheVersion {
    public static let renderer = 6
}

/// Everything a film-strip thumbnail depends on. A thumbnail is the default recipe of one film
/// (`Recipe(filmID:)`) applied to the cropped, downscaled picture, so the inputs are the film (id and a
/// signature of its LUT file / character), the picture (a hash of the downscaled base pixels, which
/// already carries the crop, the RAW develop settings and the orientation), the crop, the pipeline
/// number of the default recipe, the thumbnail size and `ThumbnailCacheVersion.renderer`.
public struct ThumbnailKey: Hashable, Sendable {
    public var filmID: String?
    public var filmSignature: String
    public var sourceHash: UInt64
    public var crop: CropSettings
    public var longSide: Int
    public var pipeline: Int
    public var renderer: Int

    public init(filmID: String?, filmSignature: String = "", sourceHash: UInt64, crop: CropSettings, longSide: Int,
                pipeline: Int = Recipe.currentPipeline, renderer: Int = ThumbnailCacheVersion.renderer) {
        self.filmID = filmID
        self.filmSignature = filmSignature
        self.sourceHash = sourceHash
        self.crop = crop
        self.longSide = longSide
        self.pipeline = pipeline
        self.renderer = renderer
    }

    /// A stable file name: FNV-1a over a canonical text of the key.
    public var fileName: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let cropText = (try? enc.encode(crop)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(crop)"
        let text = "r\(renderer)|p\(pipeline)|s\(longSide)|\(filmID ?? "-")|\(filmSignature)|\(sourceHash)|\(cropText)"
        return String(format: "%016llx.jpg", ThumbnailHash.fnv1a(Array(text.utf8)))
    }
}

public enum ThumbnailHash {
    public static func fnv1a(_ bytes: [UInt8], seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var h = seed
        for b in bytes { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// A signature of a film's look inputs: the LUT file's size and modification time (nothing for
    /// a procedural look) and the character that drives grain and halation.
    public static func filmSignature(_ film: Film, directory: URL) -> String {
        var parts = [film.file, "\(film.resolvedCharacter)", film.isMonochrome ? "mono" : "colour"]
        if film.proceduralID == nil,
           let v = try? directory.appendingPathComponent(film.file).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            parts.append("\(v.fileSize ?? 0)-\(Int((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))")
        }
        return String(format: "%016llx", fnv1a(Array(parts.joined(separator: "|").utf8)))
    }
}

/// Small JPEG files of rendered film-strip thumbnails in `Library/Caches/<bundle id or "Mira">/Thumbnails/`.
/// Bounded by total size: the least recently used files (by modification date, touched on every hit) go
/// first. Safe to call from any thread; keep calls off the main actor, they do file IO.
public final class ThumbnailDiskCache: @unchecked Sendable {
    public static let defaultByteLimit = 200 * 1024 * 1024

    public let directory: URL
    public let byteLimit: Int
    private let lock = NSLock()
    private var storesSinceTrim = 0
    private var trimmedOnce = false

    public init(directory: URL, byteLimit: Int = ThumbnailDiskCache.defaultByteLimit) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    public static func defaultDirectory(bundle: Bundle = .main) -> URL? {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true) else { return nil }
        return caches.appendingPathComponent(bundle.bundleIdentifier ?? "Mira", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// The cache for this process (the app and the Photos extension each have their own folder).
    public static func standard(bundle: Bundle = .main) -> ThumbnailDiskCache? {
        defaultDirectory(bundle: bundle).map { ThumbnailDiskCache(directory: $0) }
    }

    private func url(_ key: ThumbnailKey) -> URL { directory.appendingPathComponent(key.fileName) }

    /// The cached thumbnail, decoded, or nil. A hit marks the file as recently used.
    public func load(_ key: ThumbnailKey) -> CGImage? {
        let file = url(key)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    public func contains(_ key: ThumbnailKey) -> Bool {
        FileManager.default.fileExists(atPath: url(key).path)
    }

    public func store(_ image: CGImage, key: ThumbnailKey) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (data as Data).write(to: url(key), options: .atomic)
        lock.lock()
        storesSinceTrim += 1
        let due = !trimmedOnce || storesSinceTrim >= 32
        if due { storesSinceTrim = 0; trimmedOnce = true }
        lock.unlock()
        if due { trim() }
    }

    /// Deletes the least recently used files until the folder fits `byteLimit`.
    public func trim() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for u in urls where u.pathExtension == "jpg" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = v?.fileSize ?? 0
            files.append((u, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > byteLimit else { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            if total <= byteLimit { break }
            try? fm.removeItem(at: f.url)
            total -= f.size
        }
    }

    /// Total size of the cached files, in bytes.
    public var totalBytes: Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "jpg" }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
