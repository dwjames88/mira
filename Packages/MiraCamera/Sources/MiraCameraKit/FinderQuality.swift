import Foundation
import MiraCore

/// How the finder is rendered right now.
public struct FinderQuality: Sendable, Equatable {
    /// Fraction of the drawable size the finder renders at (1 or 0.75), upscaled on the GPU.
    public var renderScale: Double
    /// Resolution of halation, bloom and grain relative to the finder (1 or 0.5).
    public var textureScale: Double
    /// Grain shimmers in the finder; false drops it (the saved photo still gets its grain).
    public var grainLive: Bool
    /// Finder frame rate, 30 or 24.
    public var frameRate: Int

    public init(renderScale: Double = 1, textureScale: Double = 1, grainLive: Bool = true, frameRate: Int = 30) {
        self.renderScale = renderScale
        self.textureScale = textureScale
        self.grainLive = grainLive
        self.frameRate = frameRate
    }

    public static let full = FinderQuality()
}

/// The user / developer override for the finder quality. `.auto` lets `FallbackLadder` decide.
public enum FinderQualityMode: String, Sendable, Equatable, Codable, CaseIterable {
    case auto, full, halfTexture, grainOff, reduced
}

/// The rungs, best first. AUTO walks `automatic` (full, grain off, reduced, low frame rate);
/// `halfTexture` is only reachable as a pinned override (it measured slightly slower than full).
public enum FinderLevel: Int, Sendable, Comparable, CaseIterable {
    case full, halfTexture, grainOff, reduced, lowFrameRate

    public static func < (a: FinderLevel, b: FinderLevel) -> Bool { a.rawValue < b.rawValue }

    /// The levels AUTO steps through, best first. Each includes the savings of the ones above it.
    public static let automatic: [FinderLevel] = [.full, .grainOff, .reduced, .lowFrameRate]

    /// The quality for this rung. `grainLiveSetting` false (the user's FINDER: OFF) removes grain on every rung.
    public func quality(grainLiveSetting: Bool = true) -> FinderQuality {
        var q = FinderQuality(grainLive: grainLiveSetting)
        if self == .halfTexture { q.textureScale = 0.5 }
        if self >= .grainOff { q.grainLive = false }
        if self >= .reduced { q.renderScale = 0.75 }
        if self >= .lowFrameRate { q.frameRate = 24 }
        return q
    }
}

/// `ProcessInfo.ThermalState` (and the camera's system pressure) as the ladder sees it.
public enum FinderThermalLevel: Int, Sendable, Comparable, Equatable {
    case nominal, fair, serious, critical
    public static func < (a: FinderThermalLevel, b: FinderThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Steps the finder down when frames are slow and back up when they are fast, with hysteresis.
/// Pure: feed it `(frameMilliseconds, timestamp)` samples and the thermal level, read `quality`.
public struct FallbackLadder: Sendable {
    /// A median frame time above this (ms) for `stepDownAfter` seconds steps down one level.
    public static let slowThreshold = 30.0
    /// A median below this (ms) for `stepUpAfter` seconds steps up one level.
    public static let fastThreshold = 20.0
    public static let stepDownAfter = 1.0
    public static let stepUpAfter = 5.0
    /// Samples older than this many seconds leave the median window.
    public static let window = 1.0

    public var mode: FinderQualityMode
    /// The user's FINDER: LIVE / OFF setting.
    public var grainLiveSetting: Bool
    public var thermal: FinderThermalLevel

    private var adaptive: FinderLevel = .full
    private var samples: [(ms: Double, t: Double)] = []
    private var slowSince: Double?
    private var fastSince: Double?

    public init(mode: FinderQualityMode = .auto, grainLiveSetting: Bool = true, thermal: FinderThermalLevel = .nominal) {
        self.mode = mode
        self.grainLiveSetting = grainLiveSetting
        self.thermal = thermal
    }

    /// The level in force: the override when set, else the measured level raised to the thermal floor.
    public var level: FinderLevel {
        switch mode {
        case .full: .full
        case .halfTexture: .halfTexture
        case .grainOff: .grainOff
        case .reduced: .reduced
        case .auto: max(adaptive, thermalFloor)
        }
    }

    public var quality: FinderQuality { level.quality(grainLiveSetting: grainLiveSetting) }

    private var thermalFloor: FinderLevel {
        switch thermal {
        case .nominal, .fair: .full
        case .serious: .grainOff
        case .critical: .lowFrameRate
        }
    }

    /// Records a finder frame time (milliseconds) at `timestamp` (seconds, monotonic).
    public mutating func record(frameMilliseconds ms: Double, at timestamp: Double) {
        guard ms.isFinite, mode == .auto else { return }
        // A gap longer than the window (the camera paused, or the level was pinned for a while): the pending slow /
        // fast timers no longer describe one continuous run of frames, so they start over.
        if let last = samples.last, timestamp - last.t > Self.window { resetWindow() }
        samples.append((ms, timestamp))
        samples.removeAll { timestamp - $0.t > Self.window }
        let median = Self.median(samples.map(\.ms))

        if median > Self.slowThreshold {
            fastSince = nil
            let since = slowSince ?? timestamp
            slowSince = since
            if timestamp - since > Self.stepDownAfter, let i = FinderLevel.automatic.firstIndex(of: adaptive),
               i + 1 < FinderLevel.automatic.count {
                adaptive = FinderLevel.automatic[i + 1]
                resetWindow()
            }
        } else if median < Self.fastThreshold {
            slowSince = nil
            let since = fastSince ?? timestamp
            fastSince = since
            if timestamp - since >= Self.stepUpAfter, let i = FinderLevel.automatic.firstIndex(of: adaptive), i > 0 {
                adaptive = FinderLevel.automatic[i - 1]
                resetWindow()
            }
        } else {
            slowSince = nil
            fastSince = nil
        }
    }

    private mutating func resetWindow() {
        samples.removeAll()
        slowSince = nil
        fastSince = nil
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Derives the finder's recipe from the user's. Finder-only state never reaches a saved recipe.
public enum FinderRecipe {
    /// The user's recipe as the finder renders it: grain removed when the finder grain is off.
    /// Returns a copy; the user's recipe is untouched and is what the capture saves.
    public static func recipe(from user: Recipe, quality: FinderQuality) -> Recipe {
        var r = user
        if !quality.grainLive { r.grainAmount = 0 }
        return r
    }

    /// `Renderer.withPreviewScale` argument: how much smaller the finder is than the capture (at most 1).
    public static func previewScale(finderLongSide: Double, captureLongSide: Double) -> Double {
        guard finderLongSide > 0, captureLongSide > 0 else { return 1 }
        return min(1, finderLongSide / captureLongSide)
    }

    /// A per-frame grain seed for the finder so grain shimmers. At most 24 bits (exact in a Float), never 0.
    /// Used only with `Renderer.withGrainSeed`; never stored in a recipe.
    public static func grainSeed(frameIndex: Int) -> Double {
        var z = UInt64(bitPattern: Int64(frameIndex)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double((z & 0xFF_FFFF) | 1)
    }
}
