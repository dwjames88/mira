import AppKit
import SwiftUI

/// Procedural film grain: a seeded, tileable noise tile generated once and cached.
///
/// The site uses an SVG `feTurbulence` tile whose red channel becomes alpha (gamma 2.4), white specks on
/// ink and black specks on paper. This is the same idea: fine fractal-ish noise, alpha = noise^2.4.
public enum FFGrain {
    /// Edge of the square tile, in pixels.
    public static let tileSize = 256
    public static let seed: UInt64 = 0xF1E1_D0F2_A3E5
    /// Exponent applied to the noise to pull the distribution apart (styles.css feFuncA gamma).
    public static let gamma = 2.4

    /// The tile's alpha channel, `tileSize * tileSize` bytes, row-major. Generated once.
    public static var alphaMask: [UInt8] { cache.mask }

    /// Specks as white (for ink) or black (for paper) on transparent, premultiplied RGBA.
    public static func tile(white: Bool) -> CGImage { white ? cache.white : cache.black }

    private struct Cache: @unchecked Sendable {
        let mask: [UInt8]
        let white: CGImage
        let black: CGImage
    }

    private static let cache: Cache = {
        let n = tileSize
        var rng = SplitMix64(seed: seed)
        // Two uniform samples per texel (triangular distribution around 0.5), then a light wrapped blur so
        // the specks are slightly clustered like turbulence rather than TV static.
        var raw = [Double](repeating: 0, count: n * n)
        for i in 0..<raw.count { raw[i] = (rng.nextUnit() + rng.nextUnit()) * 0.5 }
        var mask = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var sum = 0.0
                for (dx, dy, w) in [(0, 0, 4.0), (1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0)] {
                    sum += raw[((y + dy + n) % n) * n + (x + dx + n) % n] * w
                }
                let v = sum / 8
                // Re-expand the contrast the blur removed, around 0.5.
                let stretched = min(1, max(0, (v - 0.5) * 2.1 + 0.5))
                mask[y * n + x] = UInt8((pow(stretched, gamma) * 255).rounded())
            }
        }
        func image(white: Bool) -> CGImage {
            var pixels = [UInt8](repeating: 0, count: n * n * 4)
            for i in 0..<(n * n) {
                let a = mask[i]
                let c: UInt8 = white ? a : 0 // premultiplied
                pixels[i * 4] = c; pixels[i * 4 + 1] = c; pixels[i * 4 + 2] = c; pixels[i * 4 + 3] = a
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        return Cache(mask: mask, white: image(white: true), black: image(white: false))
    }()
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// The grain layer itself: tiled, one tile pixel per device pixel, never intercepts hits.
public struct FFGrainView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    private let opacity: Double

    public init(opacity: Double = 0.12) {
        self.opacity = opacity
    }

    public var body: some View {
        let dark = scheme == .dark
        // Black specks read stronger on paper, so they run at about 60% (site: 0.16 -> 0.10).
        let o = dark ? opacity : opacity * 0.6
        let image = Image(decorative: FFGrain.tile(white: dark), scale: max(displayScale, 1))
        Rectangle()
            .fill(ImagePaint(image: image))
            .opacity(o)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Solid ground colour with grain on top, for backgrounds (chrome and panels, never over a photograph).
public struct FFGroundBackground: View {
    private let base: Color
    private let grain: Double

    public init(base: Color = FieldFramesTheme.ink, grain: Double = 0.12) {
        self.base = base
        self.grain = grain
    }

    public var body: some View {
        ZStack {
            base
            FFGrainView(opacity: grain)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Overlays grain on a panel or chrome. Do not apply to a view that contains the photograph.
    public func ffGrain(opacity: Double = 0.12) -> some View {
        overlay { FFGrainView(opacity: opacity) }
    }
}
