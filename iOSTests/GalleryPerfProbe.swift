import MiraCore
import Photos
import SwiftUI
import UIKit
import XCTest
@testable import Mira

/// Opt-in measurement of the real album grid against the simulator's Photos library
/// (TEST_RUNNER_MIRA_GALLERY_PROBE=1, read-only: it creates, edits and deletes nothing).
/// Prints one `GALLERYPROBE ...` line: time to the first thumbnail request, time until the requests stop,
/// request counts after the first screen / after a scripted scroll / after scrolling back, and the frame
/// intervals of the scroll (display link). Same command before and after a change = comparable numbers.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private(set) var deltas: [Double] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    var onFrame: ((CFTimeInterval) -> Void)?

    func start() {
        deltas = []
        lastTimestamp = 0
        started = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        if started == 0 { started = l.timestamp }
        if lastTimestamp != 0 { deltas.append((l.timestamp - lastTimestamp) * 1000) }
        lastTimestamp = l.timestamp
        onFrame?(l.timestamp - started)
    }
}

final class GalleryPerfProbe: XCTestCase {
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

    @MainActor
    private func waitUntilQuiet(_ metrics: ThumbnailMetrics, quiet: Double, limit: Double) async -> Double {
        let t0 = CACurrentMediaTime()
        var last = metrics.snapshot.requests, lastChange = t0
        while CACurrentMediaTime() - t0 < limit {
            try? await Task.sleep(for: .milliseconds(20))
            let r = metrics.snapshot.requests, now = CACurrentMediaTime()
            if r != last { last = r; lastChange = now }
            if now - lastChange > quiet { break }
        }
        return (lastChange - t0) * 1000
    }

    @MainActor
    func testAlbumGridFirstPaintScrollAndRequests() async throws {
        let nodeID = ProcessInfo.processInfo.environment["MIRA_GALLERY_PROBE_NODE"] ?? "all"
        let gallery = GalleryModel()
        await gallery.start()
        let editor = EditorViewModel()
        let metrics = ThumbnailMetrics.shared
        metrics.reset()

        let size = CGSize(width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: NavigationStack {
            AlbumGridView(gallery: gallery, editor: editor, nodeID: nodeID, title: "Probe")
        }.preferredColorScheme(.dark))
        window.rootViewController = host
        let t0 = CACurrentMediaTime()
        window.makeKeyAndVisible()

        var firstRequestMs: Double?
        while CACurrentMediaTime() - t0 < 20 {
            try await Task.sleep(for: .milliseconds(10))
            if metrics.snapshot.requests > 0 { firstRequestMs = (CACurrentMediaTime() - t0) * 1000; break }
        }
        let settleMs = await waitUntilQuiet(metrics, quiet: 0.8, limit: 20) + (firstRequestMs ?? 0)
        let afterFirstScreen = metrics.snapshot

        guard let scroll = findScrollView(in: host.view) else {
            print("GALLERYPROBE node=\(nodeID) no-scrollable-grid first_request_ms=\(Int(firstRequestMs ?? -1)) requests=\(afterFirstScreen.requests)")
            window.isHidden = true
            return
        }
        let travel = max(0, scroll.contentSize.height - scroll.bounds.height)
        let speed: CGFloat = 2400   // points per second
        let duration = min(4.0, Double(travel / speed))
        let recorder = FrameRecorder()
        let finished = expectation(description: "scrolled")
        let startOffset = scroll.contentOffset.y
        recorder.onFrame = { elapsed in
            let y = startOffset + CGFloat(elapsed) * speed
            scroll.contentOffset.y = min(y, startOffset + travel)
            if elapsed >= duration { recorder.stop(); finished.fulfill() }
        }
        recorder.start()
        await fulfillment(of: [finished], timeout: 30)
        let scrolledPoints = scroll.contentOffset.y - startOffset
        _ = await waitUntilQuiet(metrics, quiet: 0.8, limit: 20)
        let afterScroll = metrics.snapshot

        // Back to the top: the thumbnails seen first are in the memory cache, so few or no new requests.
        let backRecorder = FrameRecorder()
        let back = expectation(description: "scrolled back")
        let from = scroll.contentOffset.y
        backRecorder.onFrame = { elapsed in
            let y = from - CGFloat(elapsed) * speed * 2
            scroll.contentOffset.y = max(y, 0)
            if y <= 0 { backRecorder.stop(); back.fulfill() }
        }
        backRecorder.start()
        await fulfillment(of: [back], timeout: 30)
        _ = await waitUntilQuiet(metrics, quiet: 0.8, limit: 20)
        let afterBack = metrics.snapshot

        let d = recorder.deltas.sorted()
        func pct(_ p: Double) -> Double { d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count) * p))] }
        let slow = d.filter { $0 > 20 }.count
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        print("GALLERYPROBE node=\(nodeID) first_request_ms=\(Int(firstRequestMs ?? -1)) settled_ms=\(Int(settleMs)) "
              + "first_screen_requests=\(afterFirstScreen.requests) cache_hits=\(afterBack.cacheHits) preheated=\(afterBack.assetsPreheated) "
              + "scrolled_pt=\(Int(scrolledPoints)) scroll_requests=\(afterScroll.requests - afterFirstScreen.requests) frames=\(d.count) "
              + "p50_ms=\(f(pct(0.5))) p95_ms=\(f(pct(0.95))) max_ms=\(f(d.last ?? 0)) slow_gt20ms=\(slow) "
              + "back_requests=\(afterBack.requests - afterScroll.requests) stops=\(afterBack.stopCalls) stop_all=\(afterBack.stopAllCalls)")
        window.isHidden = true
    }
}
