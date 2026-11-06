#if os(macOS)
import CoreImage
import MiraCore
import Observation

/// The newest latitude reading for the frame being edited (see EditorModel+Latitude.swift).
@MainActor
@Observable
public final class LatitudeSession {
    public internal(set) var reading: LatitudeReading?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var generation = 0
    init() {}
}

extension EditorModel {
    /// Wait after the last change before measuring.
    nonisolated static let latitudeDebounce: Duration = .milliseconds(150)

    /// The film's latitude reading for this photo, nil with no film (or before the first measurement).
    public var latitudeReading: LatitudeReading? { latitudeSession.reading }

    /// Measures the frame against the film's latitude, off the main actor, after a short pause. Newer
    /// requests supersede older ones, so a slider drag only pays for the last position. The measurement
    /// works on a 256 px copy made inside `Renderer.latitudeReading`.
    func scheduleLatitude(delay: Duration = EditorModel.latitudeDebounce) {
        let session = latitudeSession
        session.task?.cancel()
        session.generation += 1
        guard recipe.filmID != nil, let source, tab != .crop else {
            session.task = nil
            if session.reading != nil { session.reading = nil }
            return
        }
        let generation = session.generation
        let recipe = recipe
        let box = RawImageBox(image: source)
        let renderer = renderer
        session.task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let reading = await Task.detached(priority: .utility) {
                // decodeContext, not the interactive one: `box.image` may be a lazy RAW decode (see Renderer.decodeContext).
                renderer.latitudeReading(recipe, input: box.image, context: Renderer.decodeContext)
            }.value
            guard !Task.isCancelled, let self, self.latitudeSession.generation == generation else { return }
            if self.latitudeSession.reading != reading { self.latitudeSession.reading = reading }
        }
    }
}

/// Text for the latitude readouts.
public enum LatitudeFormat {
    /// Fractions of a frame above this are called out.
    public static let threshold = 0.01

    /// "\u{2212}2 / +3": stops under and over the film can record, whole numbers without a decimal.
    public static func range(under: Double, over: Double) -> String {
        "\u{2212}\(stops(under)) / +\(stops(over))"
    }

    private static func stops(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : v.formatted(.number.precision(.fractionLength(1)))
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    public static func isFlagged(_ fraction: Double) -> Bool { fraction > threshold }

    /// "12% OVER" / "4% UNDER" for the worse flagged side, nil when both are within range.
    public static func compact(_ r: LatitudeReading) -> String? {
        let over = isFlagged(r.over), under = isFlagged(r.under)
        if over && (!under || r.over >= r.under) { return "\(percent(r.over)) over" }
        if under { return "\(percent(r.under)) under" }
        return nil
    }
}
#endif
