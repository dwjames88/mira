import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Per-session cache of opened RAW assets, so reopening one is instant: the `RawDevelop` (file parsed,
/// decoder state) and the developed draft proxy (a half-float linear bitmap at preview size, so showing
/// it needs no decode) are kept for the last few assets. Bounded by asset count and by bytes; the least
/// recently used asset goes first.
// @unchecked Sendable: `entries` and `order` are only touched under `lock`.
public final class RawAssetCache: @unchecked Sendable {
    public static let shared = RawAssetCache(capacity: 6, byteBudget: 400 << 20)

    public struct ProxyKey: Hashable, Sendable {
        public var settings: RawSettings
        public var filmApplied: Bool
        public init(settings: RawSettings, filmApplied: Bool) {
            self.settings = settings
            self.filmApplied = filmApplied
        }
    }

    private struct Entry {
        var develop: RawDevelop
        var url: URL
        var orientation: CGImagePropertyOrientation?
        var proxies: [ProxyKey: DevelopedSource] = [:]
        var proxyBytes: [ProxyKey: Int] = [:]
        var bytes: Int { proxyBytes.values.reduce(0, +) }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    public let capacity: Int
    public let byteBudget: Int

    public init(capacity: Int, byteBudget: Int) {
        self.capacity = capacity
        self.byteBudget = byteBudget
    }

    public var keys: [String] { lock.lock(); defer { lock.unlock() }; return order }
    public var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return entries.values.reduce(0) { $0 + $1.bytes } }

    /// The cached `RawDevelop` for `key` when it was made for the same file and orientation.
    public func develop(forKey key: String, url: URL, orientation: CGImagePropertyOrientation?) -> RawDevelop? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], e.url == url, e.orientation == orientation else { return nil }
        touch(key)
        return e.develop
    }

    public func proxy(forKey key: String, _ proxyKey: ProxyKey) -> DevelopedSource? {
        lock.lock(); defer { lock.unlock() }
        guard let p = entries[key]?.proxies[proxyKey] else { return nil }
        touch(key)
        return p
    }

    /// Stores `develop` for `key` (replacing an entry made for another file) and, with `proxy`, a draft
    /// proxy for `proxyKey`. One proxy per asset is kept: the newest.
    public func store(key: String, url: URL, orientation: CGImagePropertyOrientation?, develop: RawDevelop,
                      proxyKey: ProxyKey? = nil, proxy: DevelopedSource? = nil) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[key]
        if e == nil || e?.url != url || e?.orientation != orientation {
            e = Entry(develop: develop, url: url, orientation: orientation)
        }
        if let proxyKey, let proxy {
            e!.proxies = [proxyKey: proxy]
            e!.proxyBytes = [proxyKey: Self.byteCount(proxy.image)]
        }
        entries[key] = e
        touch(key)
        evict()
    }

    public func removeAll() { lock.lock(); entries = [:]; order = []; lock.unlock() }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evict() {
        while order.count > capacity, let oldest = order.first { drop(oldest) }
        // Over the byte budget: first drop other assets' proxies (keeping their parsed decoder), oldest first.
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        for key in order.dropLast() where total > byteBudget {
            guard var e = entries[key], e.bytes > 0 else { continue }
            total -= e.bytes
            e.proxies = [:]; e.proxyBytes = [:]
            entries[key] = e
        }
    }

    private func drop(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    static func byteCount(_ image: CIImage) -> Int {
        let e = image.extent
        guard e.width.isFinite, e.height.isFinite else { return 0 }
        return Int(e.width * e.height) * 8
    }
}

// MARK: - Opening

public enum RawOpener {
    // @unchecked Sendable: CIImage and RawDevelop are immutable or internally locked; the frame is a value handed to one consumer.
    public struct Frame: @unchecked Sendable {
        public var develop: RawDevelop
        public var source: DevelopedSource
        /// True when the frame came from the proxy cache (no decode happened).
        public var cached: Bool
    }

    private static let proxyLock = NSLock()
    private static let proxyContext = Renderer.makeContext()

    /// The first editable frame of a RAW file: a draft-mode decode at preview size (or the cached proxy
    /// for the same asset and settings), rendered into a bitmap so showing it never decodes again.
    /// `cacheKey` is nil to skip the cache. Runs on the calling thread: call it off the main actor.
    public static func openDraft(
        url: URL, orientation: CGImagePropertyOrientation?, settings: RawSettings, filmApplied: Bool,
        cacheKey: String?, cache: RawAssetCache = .shared
    ) -> Frame? {
        let proxyKey = RawAssetCache.ProxyKey(settings: settings, filmApplied: filmApplied)
        var develop = cacheKey.flatMap { cache.develop(forKey: $0, url: url, orientation: orientation) }
        if let cacheKey, let develop, let hit = cache.proxy(forKey: cacheKey, proxyKey) {
            return Frame(develop: develop, source: hit, cached: true)
        }
        if develop == nil { develop = RawDevelop(url: url, orientation: orientation) }
        guard let develop else { return nil }
        guard let developed = develop.develop(settings, filmApplied: filmApplied, draft: true, scale: develop.previewScale())
        else { return nil }
        let proxy = bitmapProxy(of: developed) ?? developed
        if let cacheKey {
            cache.store(key: cacheKey, url: url, orientation: orientation, develop: develop, proxyKey: proxyKey, proxy: proxy)
        }
        return Frame(develop: develop, source: proxy, cached: false)
    }

    /// The full-quality preview decode (draft mode off, same size as the draft) of the current settings.
    public static func refine(
        develop: RawDevelop, settings: RawSettings, filmApplied: Bool
    ) -> DevelopedSource? {
        develop.develop(settings, filmApplied: filmApplied, draft: false, scale: develop.previewScale())
    }

    /// Renders a developed image into a half-float extended linear Display P3 bitmap and wraps it again
    /// (tags kept). Values above 1 survive, so film headroom is unaffected.
    static func bitmapProxy(of developed: DevelopedSource) -> DevelopedSource? {
        let extent = developed.image.extent
        guard !extent.isEmpty, !extent.isInfinite,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        proxyLock.lock(); defer { proxyLock.unlock() }
        guard let cg = proxyContext.createCGImage(developed.image, from: extent, format: .RGBAh, colorSpace: space)
        else { return nil }
        var image = CIImage(cgImage: cg, options: [.colorSpace: space])
        image = image.withMiraExposureTime(developed.image.miraExposureTime)
        return DevelopedSource(image: image, headroom: developed.headroom)
    }
}
