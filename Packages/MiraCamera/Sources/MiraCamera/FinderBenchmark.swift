#if os(iOS)
import CoreImage
import Foundation
import MiraCameraKit
import MiraCore
import Synchronization

/// Renders frames through the exact `FinderRenderer.consume` path into an offscreen texture and times them.
public enum FinderBenchmark {
    public struct Result: Sendable, Equatable {
        /// Wall milliseconds per frame, from the start of `consume` (graph build and encode) to GPU completion.
        public var medianMS: Double
        public var p95MS: Double
        public var frames: Int
        /// Frames skipped (should be 0: the benchmark waits for each frame).
        public var skipped: Int
    }

    /// - Parameters:
    ///   - frameImage: the camera image for frame `i` (make it differ per frame so no render is a cache hit).
    ///   - size: the drawable size in pixels.
    ///   - mode: a pinned quality level (`.auto` lets the ladder move during the run).
    ///   - rotation: the frame's rotation angle in degrees.
    ///   - captureLongSide: long side of the photo the capture saves.
    public static func run(
        frameImage: (Int) -> CIImage, size: (width: Int, height: Int), mode: FinderQualityMode = .full,
        recipe: Recipe, renderer: Renderer? = nil, rotation: Double = 0, captureLongSide: Double = 4032,
        frames: Int = 90, warmup: Int = 20
    ) -> Result? {
        guard let finder = FinderRenderer(renderer: renderer) else { return nil }
        finder.attachOffscreen(width: size.width, height: size.height)
        finder.update {
            $0.recipe = recipe
            $0.mode = mode
            $0.captureLongSide = captureLongSide
        }
        var samples: [Double] = []
        var skipped = 0
        for i in 0..<(warmup + frames) {
            let box = Mutex<Double?>(nil)
            let done = DispatchSemaphore(value: 0)
            let frame = FinderFrame(image: frameImage(i), rotationAngle: rotation, exposureTime: 1.0 / 60,
                                    timestamp: Double(i) / 30, index: i)
            let started = finder.consume(frame) { ms in
                box.withLock { $0 = ms }
                done.signal()
            }
            if started {
                _ = done.wait(timeout: .now() + 5)
                if i >= warmup, let ms = box.withLock({ $0 }) { samples.append(ms) }
            } else if i >= warmup {
                skipped += 1
            }
        }
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return Result(medianMS: 0, p95MS: 0, frames: 0, skipped: skipped) }
        return Result(medianMS: sorted[sorted.count / 2],
                      p95MS: sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)],
                      frames: sorted.count, skipped: skipped)
    }

    public struct CardResult: Sendable, Equatable {
        /// Milliseconds from the door asking for the cards (after one frame has been consumed) to the first card published.
        public var firstMS: Double
        /// ... to the last of the requested cards.
        public var allMS: Double
        public var count: Int
        /// ... for a second request of the same cards on the same scene (served from the cache).
        public var cachedAllMS: Double
    }

    /// Time to first card and to all cards through the real `FinderRenderer` card path from a cold renderer:
    /// one frame is consumed, then `ids` are requested; no LUT is prewarmed.
    public static func cardLatency(frame: CIImage, ids: [String], renderer: Renderer) -> CardResult? {
        guard let finder = FinderRenderer(renderer: renderer) else { return nil }
        finder.attachOffscreen(width: 390, height: 520)
        let state = Mutex((first: Double?.none, all: Double?.none, seen: Set<String>()))
        let done = DispatchSemaphore(value: 0)
        let t0 = Mutex(DispatchTime.now().uptimeNanoseconds)
        let wanted = Set(ids)
        finder.setCardsHandler { cards in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.withLock { $0 }) / 1e6
            let finished: Bool = state.withLock { st in
                if st.first == nil { st.first = ms }
                st.seen.formUnion(cards.keys)
                if st.all == nil, st.seen.isSuperset(of: wanted) { st.all = ms; return true }
                return false
            }
            if finished { done.signal() }
        }
        let frameDone = DispatchSemaphore(value: 0)
        _ = finder.consume(FinderFrame(image: frame, rotationAngle: 0, exposureTime: 1.0 / 60, timestamp: 0, index: 0)) { _ in frameDone.signal() }
        _ = frameDone.wait(timeout: .now() + 5)
        t0.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        finder.update { $0.cardFilmIDs = ids }
        guard done.wait(timeout: .now() + 60) == .success else { return nil }
        let (first, all) = state.withLock { ($0.first ?? 0, $0.all ?? 0) }

        // Door closed and opened again on the same scene: the cache republishes without rendering.
        finder.update { $0.cardFilmIDs = [] }
        state.withLock { $0 = (nil, nil, []) }
        t0.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        finder.update { $0.cardFilmIDs = ids }
        _ = done.wait(timeout: .now() + 30)
        let cached = state.withLock { $0.all ?? 0 }
        return CardResult(firstMS: first, allMS: all, count: ids.count, cachedAllMS: cached)
    }
}
#endif
