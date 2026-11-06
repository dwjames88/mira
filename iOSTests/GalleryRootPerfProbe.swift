import MiraCore
import Photos
import SwiftUI
import UIKit
import XCTest
@testable import Mira

/// Opt-in measurement of the gallery ROOT (the album list) against the simulator's Photos library
/// (TEST_RUNNER_MIRA_GALLERY_PROBE=1). Meant for the dedicated "Mira QA Library" simulator seeded by
/// `LibrarySeedTool`. It hosts the real `GalleryView` and prints one `GALLERYROOT ...` line:
///   first_sections_ms   start -> the first sections are published (the first screen can draw)
///   all_ready_ms        start -> every first-screen count is known and the cover requests went quiet
///   open_*              main-thread frame intervals (display link) from start to all_ready
///   scroll_*            scripted scroll of the album list: frame intervals
///   change_*            one library change (favorite toggled on one asset, then back): ms until the favourites
///                       count shows it, main-thread max frame meanwhile, cover lookups it caused
///   loader_*            `SidebarLoader` timed on a background thread, in parts
/// The change step edits one asset's favorite flag and restores it; allowed on the dedicated perf simulator only.
@MainActor
private final class RootFrameRecorder: NSObject {
    private var link: CADisplayLink?
    private(set) var deltas: [Double] = []
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    var onFrame: ((CFTimeInterval) -> Void)?

    func start() {
        deltas = []; last = 0; started = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        if started == 0 { started = l.timestamp }
        if last != 0 { deltas.append((l.timestamp - last) * 1000) }
        last = l.timestamp
        onFrame?(l.timestamp - started)
    }
}

struct FrameStats {
    var count = 0, p50 = 0.0, p95 = 0.0, max = 0.0, over33 = 0, over50 = 0
    init(_ deltas: [Double]) {
        let d = deltas.sorted()
        count = d.count
        func pct(_ p: Double) -> Double { d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count) * p))] }
        p50 = pct(0.5); p95 = pct(0.95); max = d.last ?? 0
        over33 = d.filter { $0 > 33 }.count
        over50 = d.filter { $0 > 50 }.count
    }
    func line(_ prefix: String) -> String {
        String(format: "%@frames=%d %@p50_ms=%.1f %@p95_ms=%.1f %@max_ms=%.1f %@gt33=%d %@gt50=%d",
               prefix, count, prefix, p50, prefix, p95, prefix, max, prefix, over33, prefix, over50)
    }
}

final class GalleryRootPerfProbe: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_GALLERY_PROBE"] == "1",
                          "Opt-in: set TEST_RUNNER_MIRA_GALLERY_PROBE=1")
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized || s == .limited, "Photos not authorized (\(s.rawValue))")
    }

    @MainActor private func findScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView, s.contentSize.height > s.bounds.height { return s }
        for sub in view.subviews { if let s = findScrollView(in: sub) { return s } }
        return nil
    }

    /// The nodes whose counts the first screen needs: the LIBRARY section and the first tiles after it.
    @MainActor private func firstScreenNodeIDs(_ gallery: GalleryModel) -> [String] {
        var ids: [String] = []
        for section in gallery.sections {
            let nodes = SidebarModel.visible(section.nodes).filter { !$0.isFolder }
            ids += nodes.prefix(section.id == "library" ? 3 : 2).map(\.id)
            if ids.count >= 5 { break }
        }
        return ids
    }

    /// PhotoKit runs the change block on its own queue: it must not be main-actor isolated.
    nonisolated private static func setFavorite(_ asset: Unchecked<PHAsset>, _ value: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: asset.value).isFavorite = value
        }
    }

    private static func ms(_ from: CFTimeInterval) -> Double { (CACurrentMediaTime() - from) * 1000 }

    @MainActor
    func testGalleryRootOpenScrollChange() async throws {
        let gallery = GalleryModel()
        let editor = EditorViewModel()
        let metrics = ThumbnailMetrics.shared
        metrics.reset()

        let size = CGSize(width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: GalleryView(editor: editor, gallery: gallery).preferredColorScheme(.dark))
        window.rootViewController = host

        // ---- open: window shown at t0; GalleryView's own .task starts the gallery model.
        let openFrames = RootFrameRecorder()
        openFrames.start()
        let t0 = CACurrentMediaTime()
        window.makeKeyAndVisible()
        var firstSectionsMs: Double?
        var countsReadyMs: Double?
        var lastRequestMs = 0.0
        var lastRequests = 0
        var watched: [String] = []
        while Self.ms(t0) < 60 * 1000 {
            try await Task.sleep(for: .milliseconds(5))
            if firstSectionsMs == nil, gallery.loadedSections { firstSectionsMs = Self.ms(t0) }
            let r = metrics.snapshot.requests
            if r != lastRequests { lastRequests = r; lastRequestMs = Self.ms(t0) }
            if firstSectionsMs != nil {
                if watched.isEmpty { watched = firstScreenNodeIDs(gallery) }
                if countsReadyMs == nil, !watched.isEmpty, watched.allSatisfy({ gallery.count(for: $0) != nil }) {
                    countsReadyMs = Self.ms(t0)
                }
                if let ready = countsReadyMs, Self.ms(t0) - max(ready, lastRequestMs) > 700 { break }
            }
        }
        let allReadyMs = max(countsReadyMs ?? 0, lastRequestMs)
        openFrames.stop()
        // Frames up to all-ready only (the 700 ms quiet tail is idle).
        let openStats = FrameStats(Array(openFrames.deltas.prefix(Int(allReadyMs / 16.0))))
        let coverRequestsOpen = metrics.snapshot.requests

        // ---- scroll the album list
        var scrollStats = FrameStats([])
        var scrolledPt = 0
        if let scroll = findScrollView(in: host.view) {
            let travel = max(0, scroll.contentSize.height - scroll.bounds.height)
            let speed: CGFloat = 2400
            let duration = min(5.0, Double(travel / speed))
            let rec = RootFrameRecorder()
            let done = expectation(description: "scrolled")
            let start = scroll.contentOffset.y
            rec.onFrame = { elapsed in
                scroll.contentOffset.y = min(start + CGFloat(elapsed) * speed, start + travel)
                if elapsed >= duration { rec.stop(); done.fulfill() }
            }
            rec.start()
            await fulfillment(of: [done], timeout: 30)
            scrollStats = FrameStats(rec.deltas)
            scrolledPt = Int(scroll.contentOffset.y - start)
            scroll.contentOffset.y = 0
            try await Task.sleep(for: .milliseconds(1200))
        }

        // ---- one library change: favorite one asset, then restore it
        var changeOnMs = -1.0, changeOffMs = -1.0, changeLookups = 0
        var changeStats = FrameStats([])
        let target = PHAsset.fetchAssets(with: SidebarLoader.imageOptions()).firstObject
        if let target {
            let wasFavorite = target.isFavorite
            let favBefore = gallery.count(for: "fav") ?? 0
            let rec = RootFrameRecorder()
            rec.start()
            let lookups0 = GalleryKit.coverLookups
            func toggle(to value: Bool) async throws {
                try await Self.setFavorite(Unchecked(value: target), value)
            }
            func waitFav(_ expected: Int, since: CFTimeInterval) async throws -> Double {
                while Self.ms(since) < 30_000 {
                    try await Task.sleep(for: .milliseconds(5))
                    if gallery.count(for: "fav") == expected { return Self.ms(since) }
                }
                return -1
            }
            let a = CACurrentMediaTime()
            try await toggle(to: !wasFavorite)
            changeOnMs = try await waitFav(favBefore + (wasFavorite ? -1 : 1), since: a)
            try await Task.sleep(for: .milliseconds(600))
            let b = CACurrentMediaTime()
            try await toggle(to: wasFavorite)
            changeOffMs = try await waitFav(favBefore, since: b)
            try await Task.sleep(for: .milliseconds(600))
            rec.stop()
            changeStats = FrameStats(rec.deltas)
            changeLookups = GalleryKit.coverLookups - lookups0
        }

        // ---- the loader itself, in parts, off the main thread
        let parts = await Task.detached(priority: .userInitiated) { () -> [(String, Double)] in
            func time<T>(_ work: () -> T) -> (T, Double) {
                let t = CACurrentMediaTime(); let v = work(); return (v, (CACurrentMediaTime() - t) * 1000)
            }
            var out: [(String, Double)] = []
            // The first-screen structure the iPhone builds now (collection lists + three library counts), and the
            // background pass that counts media types / utilities. loadAll below is the old all-at-once path (still the Mac's).
            out.append(("structure", time {
                SidebarLoader.structure(filter: LibraryFilter()) { SidebarLoader.fetchAssets(nodeID: $0).count }
            }.1))
            let smart = SidebarLoader.smartNodes()
            out.append(("secondary_counts", time {
                (smart.media + smart.utilities).map { SidebarLoader.fetchAssets(nodeID: $0.id).count }
            }.1))
            out.append(("loadAll_with_entries", time { SidebarLoader.loadAll() }.1))
            let (sectionsOnly, ms) = time { SidebarLoader.loadAll(withAlbumEntries: false) }
            out.append(("loadAll_sections", ms))
            out.append(("all_count", time { PHAsset.fetchAssets(with: SidebarLoader.imageOptions()).count }.1))
            out.append(("fav_count", time { PHAsset.fetchAssets(with: SidebarLoader.favoriteOptions()).count }.1))
            let (tree, treeMs) = time { SidebarLoader.userCollections(in: nil) }
            out.append(("user_album_counts", treeMs))
            out.append(("capabilities", time { SidebarLoader.albumEntries(from: tree) }.1))
            out.append(("other_sections", max(0, ms - treeMs - out[4].1 - out[5].1)))
            _ = sectionsOnly
            return out
        }.value

        let f = { (v: Double) in String(format: "%.0f", v) }
        let albumCount = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).count
        print("GALLERYROOT library=\(gallery.count(for: "all") ?? -1) albums=\(albumCount) sections=\(gallery.sections.count) "
              + "first_sections_ms=\(f(firstSectionsMs ?? -1)) counts_ready_ms=\(f(countsReadyMs ?? -1)) all_ready_ms=\(f(allReadyMs)) "
              + "cover_requests_open=\(coverRequestsOpen) " + openStats.line("open_")
              + " scrolled_pt=\(scrolledPt) " + scrollStats.line("scroll_")
              + " change_on_ms=\(f(changeOnMs)) change_off_ms=\(f(changeOffMs)) change_cover_lookups=\(changeLookups) "
              + changeStats.line("change_")
              + " " + parts.map { "loader_\($0.0)_ms=\(f($0.1))" }.joined(separator: " "))
        window.isHidden = true
    }
}
