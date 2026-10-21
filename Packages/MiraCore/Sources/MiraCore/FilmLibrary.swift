import Foundation

/// Reads `films.json` from a directory and lazily loads (and caches) each film's LUT.
///
/// With a `cacheDirectory`, resampled cubes are also persisted as compact 16-bit files so the
/// large Hald PNGs are decoded only once per install.
public final class FilmLibrary: @unchecked Sendable {
    public let directory: URL
    public let films: [Film]
    public let cacheDirectory: URL?

    /// Bump when the cache file layout or the resampling changes.
    static let cacheFormatVersion: UInt32 = 1
    private static let cacheMagic: [UInt8] = Array("ELUT".utf8)
    private static let headerSize = 12

    private let lock = NSLock()
    private var cache: [String: LUT] = [:]
    private var filmLocks: [String: NSLock] = [:]
    private let index: [String: Film]

    public init(directory: URL, cacheDirectory: URL? = nil) throws {
        self.directory = directory
        self.cacheDirectory = cacheDirectory
        let data = try Data(contentsOf: directory.appendingPathComponent("films.json"))
        let films = try JSONDecoder().decode([Film].self, from: data)
        self.films = films
        self.index = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func film(id: String) -> Film? { index[id] }

    public func lut(for film: Film) throws -> LUT {
        lock.lock()
        if let hit = cache[film.id] { lock.unlock(); return hit }
        // One loader per film at a time, so concurrent callers don't decode the same PNG twice.
        let filmLock: NSLock
        if let existing = filmLocks[film.id] { filmLock = existing } else {
            filmLock = NSLock(); filmLocks[film.id] = filmLock
        }
        lock.unlock()

        filmLock.lock()
        defer { filmLock.unlock() }
        lock.lock()
        if let hit = cache[film.id] { lock.unlock(); return hit }
        lock.unlock()

        let url = directory.appendingPathComponent(film.file)
        let cacheFile = cacheFileURL(for: film, source: url)
        let lut: LUT
        if let cacheFile, let cached = Self.readCache(cacheFile) {
            lut = cached
        } else {
            switch url.pathExtension.lowercased() {
            case "cube":
                lut = try LUT.parseCube(String(contentsOf: url, encoding: .utf8))
            default:
                lut = try LUT.loadHald(url: url)
            }
            if let cacheFile {
                // Return exactly what a later cache hit would produce.
                if let packed = Self.pack(lut), (try? packed.write(to: cacheFile, options: .atomic)) != nil {
                    let reread = Self.unpack(packed)
                    lock.lock(); cache[film.id] = reread ?? lut; lock.unlock()
                    return reread ?? lut
                }
            }
        }

        lock.lock()
        cache[film.id] = lut
        lock.unlock()
        return lut
    }

    /// Loads every LUT with up to `concurrency` loads in flight. Failures are ignored here; they
    /// surface again from `lut(for:)`.
    public func prewarmSync(concurrency: Int = 4) {
        let films = self.films
        guard !films.isEmpty else { return }
        let workers = max(1, min(concurrency, films.count))
        let next = NSLock()
        nonisolated(unsafe) var cursor = 0
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                next.lock()
                let i = cursor; cursor += 1
                next.unlock()
                if i >= films.count { return }
                _ = try? self.lut(for: films[i])
            }
        }
    }

    public func prewarm(concurrency: Int = 4) async {
        await Task.detached(priority: .utility) { self.prewarmSync(concurrency: concurrency) }.value
    }

    /// Looks for a folder named `Films` in the bundle's resources. LUTs are cached in
    /// `Library/Caches/<bundle id or "Mira">/LUTs`.
    public static func bundled(in bundle: Bundle = .main) -> FilmLibrary? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("Films", isDirectory: true) else { return nil }
        return try? FilmLibrary(directory: dir, cacheDirectory: defaultCacheDirectory(bundle: bundle))
    }

    public static func defaultCacheDirectory(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        guard let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return caches
            .appendingPathComponent(bundle.bundleIdentifier ?? "Mira", isDirectory: true)
            .appendingPathComponent("LUTs", isDirectory: true)
    }

    // MARK: Cache

    private func cacheFileURL(for film: Film, source: URL) -> URL? {
        guard let cacheDirectory,
              let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let size = values.fileSize ?? 0
        let mtime = Int((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
        let key = "\(size)-\(mtime)-\(LUT.maxHaldDimension)-v\(Self.cacheFormatVersion)"
        return cacheDirectory.appendingPathComponent("\(film.id)-\(key).lut")
    }

    /// Header: "ELUT", UInt32 version, UInt32 dimension (little endian), then UInt16 RGB texels.
    static func pack(_ lut: LUT) -> Data? {
        let n = lut.dimension
        let texels = n * n * n
        guard lut.data.count == texels * 16 else { return nil }
        var out = Data(capacity: headerSize + texels * 6)
        out.append(contentsOf: cacheMagic)
        withUnsafeBytes(of: cacheFormatVersion.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(n).littleEndian) { out.append(contentsOf: $0) }
        var body = [UInt16](repeating: 0, count: texels * 3)
        lut.data.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<texels {
                for c in 0..<3 {
                    let v = min(max(f[i * 4 + c], 0), 1)
                    body[i * 3 + c] = UInt16((v * 65535).rounded()).littleEndian
                }
            }
        }
        body.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    static func unpack(_ data: Data) -> LUT? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == cacheMagic else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        guard u32(4) == cacheFormatVersion else { return nil }
        let n = Int(u32(8))
        guard n >= 2, n <= 256 else { return nil }
        let texels = n * n * n
        guard bytes.count == headerSize + texels * 6 else { return nil }
        var out = [Float](repeating: 1, count: texels * 4)
        let scale: Float = 1.0 / 65535.0
        bytes.withUnsafeBufferPointer { b in
            var o = headerSize
            for i in 0..<texels {
                for c in 0..<3 {
                    let v = UInt16(b[o]) | UInt16(b[o + 1]) << 8
                    out[i * 4 + c] = Float(v) * scale
                    o += 2
                }
            }
        }
        return LUT(dimension: n, data: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private static func readCache(_ url: URL) -> LUT? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return unpack(data)
    }
}
