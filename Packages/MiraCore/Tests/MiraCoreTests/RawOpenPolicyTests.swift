import CoreImage
import Foundation
import Testing
@testable import MiraCore

private typealias R = AssetResourceInfo

@Suite("RAW resource selection and open policy")
struct RawOpenPolicyTests {
    @Test func rawOnlyAsset() {
        let r = [R(kind: .photo, typeIdentifier: "com.adobe.raw-image")]
        #expect(RawResourceSelection.rawIndex(in: r) == 0)
    }

    @Test func rawPlusJpegPairPicksTheAlternate() {
        let r = [R(kind: .photo, typeIdentifier: "public.jpeg"), R(kind: .alternatePhoto, typeIdentifier: "com.sony.arw-raw-image")]
        #expect(RawResourceSelection.rawIndex(in: r) == 1)
    }

    @Test func rawMadeTheOriginalWinsOverJpegAlternate() {
        let r = [R(kind: .alternatePhoto, typeIdentifier: "public.jpeg"), R(kind: .photo, typeIdentifier: "com.adobe.raw-image")]
        #expect(RawResourceSelection.rawIndex(in: r) == 1)
    }

    @Test func photoRawBeatsAlternateRaw() {
        let r = [R(kind: .alternatePhoto, typeIdentifier: "com.adobe.raw-image"), R(kind: .photo, typeIdentifier: "public.camera-raw-image")]
        #expect(RawResourceSelection.rawIndex(in: r) == 1)
    }

    @Test func jpegOnlyAndHeicHaveNoRaw() {
        #expect(RawResourceSelection.rawIndex(in: [R(kind: .photo, typeIdentifier: "public.jpeg")]) == nil)
        #expect(RawResourceSelection.rawIndex(in: [R(kind: .photo, typeIdentifier: "public.heic")]) == nil)
        #expect(RawResourceSelection.rawIndex(in: [R]()) == nil)
    }

    @Test func renderedAndUnknownResourcesAreNotCandidates() {
        let r = [R(kind: .fullSizePhoto, typeIdentifier: "com.adobe.raw-image"),
                 R(kind: .other, typeIdentifier: "com.adobe.raw-image"),
                 R(kind: .photo, typeIdentifier: "not a uti")]
        #expect(RawResourceSelection.rawIndex(in: r) == nil)
    }

    @Test func plans() {
        func plan(_ input: Bool, _ a: AssetAdjustmentState, _ raw: Bool) -> RawOpenPlan {
            RawOpenPolicy.plan(inputIsRAW: input, adjustments: a, hasRawResource: raw)
        }
        #expect(plan(true, .none, true) == .useInput)
        #expect(plan(true, .mira(rawBase: false), true) == .useInput)
        #expect(plan(false, .none, true) == .fetchResource)
        #expect(plan(false, .none, false) == .keepRendered(.noRaw))
        #expect(plan(false, .mira(rawBase: true), true) == .fetchResource)
        #expect(plan(false, .mira(rawBase: true), false) == .rawBaseMissing)
        #expect(plan(false, .mira(rawBase: false), true) == .keepRendered(.earlierEditOnRenderedFile))
        #expect(plan(false, .foreign, true) == .keepRendered(.foreignAdjustments))
    }

    @Test func rawBaseMarkerRoundTripsAndKeepsTheRecipe() throws {
        var recipe = Recipe.neutral
        recipe.exposure = 0.4
        recipe.raw.temperature = 5200
        let plain = try MiraAdjustment.adjustmentData(for: recipe)
        let marked = try MiraAdjustment.adjustmentData(for: recipe, rawBase: true)
        #expect(!MiraAdjustment.isRawBase(plain))
        #expect(MiraAdjustment.isRawBase(marked))
        #expect(MiraAdjustment.recipe(from: marked) == recipe)
        #expect(MiraAdjustment.canHandle(marked))
        #expect(!MiraAdjustment.canHandleInExtension(marked))
        #expect(MiraAdjustment.canHandleInExtension(plain))
        #expect(MiraAdjustment.state(of: nil) == .none)
        #expect(MiraAdjustment.state(of: plain) == .mira(rawBase: false))
        #expect(MiraAdjustment.state(of: marked) == .mira(rawBase: true))
        #expect(plain.formatVersion == marked.formatVersion)
    }
}

@Suite("RAW asset cache")
struct RawAssetCacheTests {
    @Test func evictsLeastRecentlyUsedAssets() throws {
        let url = try #require(RawSamples.iphoneXS)
        let develop = try #require(RawDevelop(url: url))
        let cache = RawAssetCache(capacity: 3, byteBudget: 1 << 30)
        for k in ["a", "b", "c"] { cache.store(key: k, url: url, orientation: nil, develop: develop) }
        _ = cache.develop(forKey: "a", url: url, orientation: nil)   // a is now newest
        cache.store(key: "d", url: url, orientation: nil, develop: develop)
        #expect(cache.keys == ["c", "a", "d"])
        #expect(cache.develop(forKey: "b", url: url, orientation: nil) == nil)
    }

    @Test func differentFileOrOrientationMisses() throws {
        let url = try #require(RawSamples.iphoneXS)
        let develop = try #require(RawDevelop(url: url))
        let cache = RawAssetCache(capacity: 3, byteBudget: 1 << 30)
        cache.store(key: "a", url: url, orientation: nil, develop: develop)
        #expect(cache.develop(forKey: "a", url: url, orientation: .right) == nil)
        #expect(cache.develop(forKey: "a", url: url.appendingPathExtension("x"), orientation: nil) == nil)
    }

    @Test func reopenIsServedFromTheProxyCache() throws {
        let url = try #require(RawSamples.iphoneXS)
        let cache = RawAssetCache(capacity: 2, byteBudget: 1 << 30)
        let first = try #require(RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false,
                                                     cacheKey: "x", cache: cache))
        #expect(!first.cached)
        let again = try #require(RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false,
                                                     cacheKey: "x", cache: cache))
        #expect(again.cached)
        #expect(again.source.image.extent == first.source.image.extent)
        // Other settings are not the cached proxy.
        var warm = RawSettings.identity
        warm.temperature = 7000
        let other = try #require(RawOpener.openDraft(url: url, orientation: nil, settings: warm, filmApplied: false,
                                                     cacheKey: "x", cache: cache))
        #expect(!other.cached)
        #expect(cache.totalBytes > 0)
    }

    @Test func byteBudgetDropsOlderProxiesButKeepsTheDecoder() throws {
        let url = try #require(RawSamples.iphoneXS)
        let develop = try #require(RawDevelop(url: url))
        let frame = try #require(RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false, cacheKey: nil))
        let key = RawAssetCache.ProxyKey(settings: .identity, filmApplied: false)
        let cache = RawAssetCache(capacity: 4, byteBudget: 1)
        cache.store(key: "a", url: url, orientation: nil, develop: develop, proxyKey: key, proxy: frame.source)
        cache.store(key: "b", url: url, orientation: nil, develop: develop, proxyKey: key, proxy: frame.source)
        #expect(cache.proxy(forKey: "a", key) == nil)
        #expect(cache.develop(forKey: "a", url: url, orientation: nil) != nil)
        #expect(cache.proxy(forKey: "b", key) != nil)
    }
}
