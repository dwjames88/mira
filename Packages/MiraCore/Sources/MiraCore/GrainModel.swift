import CoreGraphics
import Foundation

/// How the density noise of a stock varies with tone (`miraGrain`'s `g`). Raw values are the kernel's shape ids.
public enum GrainDensityShape: Int, Codable, Sendable, CaseIterable {
    /// Colour negative: no grain in the clear base (print black), most in the mid and light-mid tones, finer in the highlights.
    case negative = 0
    /// Reversal: grain follows the positive's density, so shadows and midtones carry it and clear highlights stay clean.
    case slide = 1
    /// Black-and-white negative: like a colour negative, with the highlights holding their grain.
    case blackAndWhite = 2
    /// Instant: diffusion mottle, only weakly tied to density.
    case instant = 3

    public var name: String {
        switch self {
        case .negative: "negative"
        case .slide: "slide"
        case .blackAndWhite: "bw"
        case .instant: "instant"
        }
    }

    public init?(name: String) {
        guard let v = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = v
    }
}

/// The numbers of Mira's grain model (see `Design/GRAIN.md`, section 6): frame mapping, footprint, amplitude
/// and the slider laws. Pure functions, shared by the renderer and the tests.
public enum GrainModel {
    /// Long side of the film frame, micrometres (35 mm).
    public static let frameLongSide = 36_000.0
    /// Gaussian std of the scan / enlarger read-out, micrometres.
    public static let scanSigma = 5.0
    /// Gaussian std equivalent to the 48 um circular aperture of the RMS granularity datasheets.
    public static let equivalentSigma = 12.0
    /// Std of a box pixel aperture in pixels (1 / sqrt(12)).
    public static let pixelAperture = 0.289

    /// Output pixel pitch in frame micrometres: the whole uncropped frame spans `uncroppedLongSidePixels`.
    public static func pitch(uncroppedLongSidePixels: Double) -> Double {
        frameLongSide / max(uncroppedLongSidePixels, 1)
    }

    /// Footprint std (scan blur and pixel aperture), micrometres.
    public static func footprintSigma(pitch: Double) -> Double {
        (scanSigma * scanSigma + pow(pixelAperture * pitch, 2)).squareRoot()
    }

    /// Amplitude gain of the grain slider: 0 off, 0.5 native (1), 1 about x2.46.
    public static func gain(slider t: Double) -> Double { t <= 0 ? 0 : pow(2 * min(t, 1), 1.3) }

    /// Grain cloud size factor of the slider (above native the grain also clumps up a little).
    public static func cloudFactor(slider t: Double) -> Double { pow(max(2 * min(max(t, 0), 1), 0.2), 0.25) }

    /// Print gain: density noise on the negative becomes a larger density change on the print (paper gamma);
    /// a slide is viewed directly. A tuned family constant (see FILM-SCIENCE.md).
    public static func printGain(_ shape: GrainDensityShape) -> Double {
        switch shape {
        case .negative: 3.0
        case .blackAndWhite: 1.7
        case .slide: 0.9
        case .instant: 1.6
        }
    }

    /// The kernel parameters for one render.
    public struct Parameters: Equatable, Sendable {
        /// Tap std, micrometres.
        public var tau: Double
        /// Lattice spacing, micrometres (fixed by the stock).
        public var lattice: Double
        /// Density noise std where the shape is 1.
        public var amplitude: Double
        public var pitch: Double
    }

    /// `sliderAmount` and `sizeSlider` are the recipe's grain amount and size (0...1, 0.5 native size);
    /// `gainBoost` multiplies the amplitude (push); `pitch` is micrometres per output pixel.
    public static func parameters(for c: FilmCharacter, sliderAmount: Double, sizeSlider: Double,
                                  gainBoost: Double = 1, pitch: Double) -> Parameters {
        let sNative = c.grainCorrelationMicrons
        let s = sNative * exp2((min(max(sizeSlider, 0), 1) - 0.5) * 2) * cloudFactor(slider: sliderAmount)
        let sigmaF = footprintSigma(pitch: pitch)
        let tau = (s * s + sigmaF * sigmaF).squareRoot()
        let tau0 = (sNative * sNative + scanSigma * scanSigma).squareRoot()
        let amp = gain(slider: sliderAmount) * gainBoost * c.grainRMS / 1000 * printGain(c.grainDensityShape)
            * ((s * s + equivalentSigma * equivalentSigma) / (tau * tau)).squareRoot()
        return Parameters(tau: tau, lattice: 1.5 * tau0, amplitude: amp, pitch: pitch)
    }

    /// A stable seed for a photo: its uncropped dimensions (rounded) and a constant. At most 24 bits (exact in a Float).
    public static func seed(uncroppedWidth w: Double, height h: Double) -> Double {
        var x = UInt64(max(w.rounded(), 1)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(max(h.rounded(), 1)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= x >> 29; x = x &* 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
        return Double(x & 0xFF_FFFF)
    }
}
