import Foundation
import MiraCore

/// Exposure times on the slider: 1/8000 s ... 60 s on a log scale, snapped to standard speeds.
public enum ExposureTimeFormat {
    public static let range: ClosedRange<Double> = log2(1.0 / 8000)...log2(60)
    /// Third-stop steps (the standard scale is a third of a stop apart).
    public static let step = 1.0 / 3.0
    /// 1/125 s: the speed at which reciprocity has no effect on any film.
    public static let neutral = 1.0 / 125

    /// The standard full- and third-stop shutter speeds, 1/8000 s ... 60 s.
    public static let standardSpeeds: [Double] = {
        let fractions: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
                                   320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4]
        let seconds: [Double] = [0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30,
                                 40, 50, 60]
        return fractions.map { 1 / $0 } + seconds
    }()

    /// The standard speed closest to `t` on the log scale.
    public static func standard(nearestTo t: Double) -> Double {
        let lt = log2(max(t, 1e-9))
        return standardSpeeds.min { abs(log2($0) - lt) < abs(log2($1) - lt) } ?? t
    }

    /// "1/250 s", "0.5 s", "2 s", "1.3 s", "30 s" (a slider position is `label(exp2(v))`).
    public static func label(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "\u{2013}" }
        if t < 0.3 { return "1/\(Int((1 / t).rounded())) s" }
        if t >= 10 { return "\(Int(t.rounded())) s" }
        let rounded = (t * 10).rounded() / 10
        return (rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)) + " s"
    }

    /// The label for a slider position (log2 of seconds).
    public static func label(sliderValue v: Double) -> String { label(exp2(v)) }
}

/// The one-line effect readout under the exposure-time control.
public enum ReciprocityFormat {
    /// Stops in thirds with a sign: "\u{2212}1\u{2153}", "\u{2212}\u{2154}"; one decimal below a sixth of a stop.
    public static func stops(_ s: Double) -> String {
        let n = Int((abs(s) * 3).rounded())
        let sign = s < 0 ? "+" : "\u{2212}"   // a loss is shown as a minus
        guard n > 0 else { return sign + String(format: "%.1f", abs(s)) }
        let whole = n / 3, rem = n % 3
        let fraction = rem == 1 ? "\u{2153}" : rem == 2 ? "\u{2154}" : ""
        return sign + (whole > 0 ? "\(whole)" : "") + fraction
    }

    /// The colour the cast pushes the picture toward: "R", "Y", "G", "C", "B", "M"; nil under 0.03 stop.
    public static func castName(_ c: ChannelStops) -> String? {
        let x = c.r - 0.5 * (c.g + c.b), y = 0.8660254 * (c.g - c.b)
        guard (x * x + y * y).squareRoot() >= 0.03 else { return nil }
        var degrees = atan2(y, x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let names = ["R", "Y", "G", "C", "B", "M"]
        return names[Int(((degrees + 30) / 60).rounded(.down)) % 6]
    }

    public static func readout(_ e: ReciprocityEffect) -> String {
        let magnitude = abs(e.lossStops)
        var parts = ["Reciprocity \(stops(e.lossStops)) \(abs(magnitude - 1) < 1e-9 ? "stop" : "stops")"]
        if let name = castName(e.cast) { parts.append("cast +\(name)") }
        let pct = Int(((e.contrastGain - 1) * 100).rounded())
        if pct != 0 { parts.append("contrast \(pct > 0 ? "+" : "\u{2212}")\(abs(pct))%") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
