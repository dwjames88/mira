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
}
#endif
