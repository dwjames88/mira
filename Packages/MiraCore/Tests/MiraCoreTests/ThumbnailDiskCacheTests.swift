import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct ThumbnailDiskCacheTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mira-thumbs-\(UUID().uuidString)")
    }

    static func solid(_ w: Int, _ h: Int, _ r: CGFloat, seed: Int = 0) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [r, 0.3, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.9, 0.9, 1])!)
        ctx.fill(CGRect(x: w / 3 + seed, y: 0, width: w / 4, height: h))
        return ctx.makeImage()!
    }

    func engine(_ image: CGImage) throws -> PreviewEngine {
        let e = PreviewEngine(renderer: Renderer(library: try emptyLibrary()), context: Renderer.sharedContext)
        e.setSource(CIImage(cgImage: image))
        return e
    }

    func key(_ film: String? = "a", hash: UInt64 = 1, crop: CropSettings = .identity, pipeline: Int = 2, renderer: Int = 1) -> ThumbnailKey {
        ThumbnailKey(filmID: film, sourceHash: hash, crop: crop, longSide: 256, pipeline: pipeline, renderer: renderer)
    }

    @Test func keyChangesWithEveryInputAndOnlyThose() {
        let base = key()
        #expect(base.fileName == key().fileName)
        var crop = CropSettings.identity
        crop.rect = CropRect(x: 0.1, y: 0, w: 0.5, h: 1)
        let names: Set<String> = [
            base.fileName, key("b").fileName, key(nil).fileName, key(hash: 2).fileName, key(crop: crop).fileName,
            key(pipeline: 1).fileName, key(renderer: 2).fileName,
            ThumbnailKey(filmID: "a", filmSignature: "x", sourceHash: 1, crop: .identity, longSide: 256, pipeline: 2).fileName,
            ThumbnailKey(filmID: "a", sourceHash: 1, crop: .identity, longSide: 128, pipeline: 2).fileName,
        ]
        #expect(names.count == 9)
    }

    /// A cache folder that cannot be created (a file is in the way) must cost nothing but the cache: no trap, no
    /// throw, loads miss.
    @Test func unwritableFolderIsHarmless() throws {
        let blocker = Self.tempDir()
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let cache = ThumbnailDiskCache(directory: blocker.appendingPathComponent("Thumbnails"))
        let k = key("a")
        cache.store(Self.solid(64, 48, 0.5), key: k)
        #expect(cache.load(k) == nil)
        #expect(!cache.contains(k))
        cache.trim()
        #expect(cache.totalBytes == 0)
    }

    @Test func sourceHashFollowsPixelsAndCropNotIdentity() throws {
        let a = try engine(Self.solid(600, 400, 0.5))
        let same = try engine(Self.solid(600, 400, 0.5))
        let other = try engine(Self.solid(600, 400, 0.8))
        let h = try #require(a.thumbnailSourceHash(crop: .identity, longSide: 256))
        #expect(h == same.thumbnailSourceHash(crop: .identity, longSide: 256))
        #expect(h != other.thumbnailSourceHash(crop: .identity, longSide: 256))
        var crop = CropSettings.identity
        crop.rect = CropRect(x: 0.5, y: 0, w: 0.5, h: 1)
        #expect(h != a.thumbnailSourceHash(crop: crop, longSide: 256))
    }

    @Test func diskHitAvoidsRendering() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailDiskCache(directory: dir)
        let e = try engine(Self.solid(600, 400, 0.5))
        nonisolated(unsafe) var got = 0
        let lock = NSLock()
        let ids: [String?] = [nil, "a", "b", "c"]
        func run(_ e: PreviewEngine) {
            e.renderThumbnails(ids: ids, crop: .identity, longSide: 128, workers: 2, diskCache: cache) { _, cg in
                lock.lock(); got += 1; lock.unlock()
                #expect(max(cg.width, cg.height) <= 128)
            }
        }
        run(e)
        #expect(got == 4)
        #expect(e.thumbnailRenderCount == 4)
        // The same engine again, and a new engine on equal pixels (a relaunch): all hits, no renders.
        run(e)
        #expect(got == 8)
        #expect(e.thumbnailRenderCount == 4)
        let relaunched = try engine(Self.solid(600, 400, 0.5))
        run(relaunched)
        #expect(got == 12)
        #expect(relaunched.thumbnailRenderCount == 0)
        // A different picture misses.
        let different = try engine(Self.solid(600, 400, 0.9))
        run(different)
        #expect(different.thumbnailRenderCount == 4)
    }

    @Test func cropChangeMissesTheCache() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailDiskCache(directory: dir)
        let e = try engine(Self.solid(600, 400, 0.5))
        e.renderThumbnails(ids: ["a"], crop: .identity, longSide: 128, diskCache: cache) { _, _ in }
        var crop = CropSettings.identity
        crop.rect = CropRect(x: 0, y: 0, w: 0.5, h: 1)
        e.renderThumbnails(ids: ["a"], crop: crop, longSide: 128, diskCache: cache) { _, _ in }
        #expect(e.thumbnailRenderCount == 2)
    }

    @Test func lruBoundDropsTheLeastRecentlyUsed() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Noisy images so each JPEG has a real size.
        func noisy(_ n: Int) -> CGImage {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            var bytes = (0..<(128 * 128 * 4)).map { UInt8(truncatingIfNeeded: ($0 &* 2654435761 &+ n * 977) >> 7) }
            for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
            let ctx = CGContext(data: &bytes, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let probe = ThumbnailDiskCache(directory: dir, byteLimit: .max)
        probe.store(noisy(0), key: key("probe"))
        let one = probe.totalBytes
        #expect(one > 1000)
        try? FileManager.default.removeItem(at: dir)

        let cache = ThumbnailDiskCache(directory: dir, byteLimit: one * 3 + one / 2)
        for i in 0..<4 {
            cache.store(noisy(i), key: key("f\(i)"))
            // Spread modification dates so the order is unambiguous.
            let past = Date(timeIntervalSinceNow: Double(i - 10) * 10)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: dir.appendingPathComponent(key("f\(i)").fileName).path)
        }
        // Use f0 (the oldest), then add f4: f1 is now the least recently used.
        #expect(cache.load(key("f0")) != nil)
        cache.store(noisy(4), key: key("f4"))
        cache.trim()
        #expect(cache.totalBytes <= one * 3 + one / 2)
        #expect(cache.contains(key("f0")))
        #expect(!cache.contains(key("f1")))
        #expect(cache.contains(key("f4")))
    }
}
