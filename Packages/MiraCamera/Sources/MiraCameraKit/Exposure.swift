import Foundation
import MiraCore

/// Exposure compensation maths: -3...+3 EV in thirds, the meter needle and the dial detents.
public enum ExposureModel {
    public static let minEV = -3.0
    public static let maxEV = 3.0
    public static let step = 1.0 / 3.0

    /// Rounds to the nearest third and clamps to -3...+3.
    public static func snapToThird(_ ev: Double) -> Double {
        guard ev.isFinite else { return 0 }
        let thirds = (min(max(ev, minEV), maxEV) * 3).rounded()
        return thirds / 3
    }

    /// Clamps to the model range intersected with the device's `minExposureTargetBias...maxExposureTargetBias`.
    public static func clamp(_ ev: Double, min lo: Double, max hi: Double) -> Double {
        guard ev.isFinite else { return 0 }
        let low = max(lo, minEV)
        let high = min(hi, maxEV)
        guard low <= high else { return 0 }
        return Swift.min(Swift.max(ev, low), high)
    }

    /// Dial label: "0", "+⅓", "−⅔", "+1⅓", with the true minus sign U+2212.
    public static func label(_ ev: Double) -> String {
        let thirds = Int((min(max(ev.isFinite ? ev : 0, minEV), maxEV) * 3).rounded())
        if thirds == 0 { return "0" }
        let n = abs(thirds)
        let whole = n / 3
        let frac = ["", "⅓", "⅔"][n % 3]
        let body = whole == 0 ? frac : (frac.isEmpty ? "\(whole)" : "\(whole)\(frac)")
        return (thirds < 0 ? "\u{2212}" : "+") + body
    }

    /// Needle position -1...1 over the -3...+3 scale. `offsetEV` is the metering error in EV:
    /// negative when the camera wants more light (the needle swings left).
    public static func needle(offsetEV: Double) -> Double {
        guard offsetEV.isFinite else { return 0 }
        return Swift.min(Swift.max(offsetEV / maxEV, -1), 1)
    }

    /// Number of third-stop detents the dial passes going from one value to another (for haptic ticks).
    public static func detentsCrossed(from: Double, to: Double) -> Int {
        abs(index(to) - index(from))
    }

    private static func index(_ ev: Double) -> Int {
        Int((min(max(ev.isFinite ? ev : 0, minEV), maxEV) * 3).rounded())
    }
}

/// The camera's real exposure as mono text: "1/125 · ISO 64 · ƒ1.8".
public enum ExposureReadout {
    /// Standard shutter denominators (1/N) a duration under 0.4 s is rounded to.
    static let standardDenominators: [Double] = [
        8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200,
        160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
    ]

    /// `duration` in seconds, `iso` as reported by the device, `aperture` as the f-number (nil omits it).
    public static func text(duration: Double, iso: Double, aperture: Double?) -> String {
        var parts = [shutterText(duration), "ISO \(Int(iso.rounded()))"]
        if let aperture, aperture > 0 { parts.append("\u{0192}" + String(format: "%.1f", aperture)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "1/125" below 0.4 s, otherwise "0.5 s", "1 s", "2 s".
    public static func shutterText(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "1/8000" }
        if duration < 0.4 {
            let n = 1 / duration
            let nearest = standardDenominators.min { abs(log($0 / n)) < abs(log($1 / n)) } ?? n
            return "1/\(Int(nearest))"
        }
        let tenths = (duration * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths)) s" : String(format: "%.1f s", tenths)
    }
}

/// The film-aware meter's second line: "UNDER 4% · OVER 1%", from MiraCore's latitude reading.
public struct LatitudeReadout: Sendable, Equatable {
    public var reading: LatitudeReading?
    /// Fractions above this (2%) turn the readout hot.
    public static let hotThreshold = 0.02

    public init(reading: LatitudeReading?) { self.reading = reading }

    public var text: String {
        guard let r = reading else { return "UNDER \u{2014} \u{00B7} OVER \u{2014}" }
        return "UNDER \(Self.percent(r.under)) \u{00B7} OVER \(Self.percent(r.over))"
    }

    /// More than 2% of the frame is above the film's shoulder (shown paper-bright).
    public var overIsHot: Bool { (reading?.over ?? 0) > Self.hotThreshold }
    public var underIsHot: Bool { (reading?.under ?? 0) > Self.hotThreshold }

    private static func percent(_ f: Double) -> String { "\(Int((min(max(f, 0), 1) * 100).rounded()))%" }
}
