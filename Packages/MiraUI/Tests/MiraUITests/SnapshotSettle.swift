import Foundation
import Testing
@testable import MiraUI

/// Round 3: waits until an `EditorModel` is fully settled, so a snapshot shows the final state and not one caught
/// mid-flight. Settled means all of:
///   - the preview for the CURRENT recipe is published (the render gate is idle and `publishedFrames` has stopped moving),
///   - every wanted film tile is on hand and no tile is still being replaced,
///   - the latitude reading task for the current recipe has finished (the reading is delivered, or deliberately absent),
///   - the preset tiles (while FILMS shows, for up to 10 s),
///   - a hover preview, when one is held, has arrived,
///   - nothing above changed for `quiet`, and the histogram is computed from the displayed frame.
/// Test code only; it reads the model's observable state and awaits its tasks, it changes nothing.
@MainActor
enum SnapshotSettle {
    static func settle(_ model: EditorModel, quiet: Duration = .milliseconds(400), timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // Preset tiles are rendered only while FILMS shows; give them up to 10 s, then accept whatever is there.
        let presetDeadline = Date().addingTimeInterval(10)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            // The latitude measurement is debounced and then runs off the main actor: wait for its task to end.
            await model.latitudeSession.task?.value
            let presetsReady = model.tab != .films || model.presetThumbnails.count >= model.presets.count || Date() > presetDeadline
            let idle = model.isPreviewIdle && model.thumbnailsSettled && model.previewImage != nil && presetsReady
            let signature = Self.signature(model)
            if idle, signature == last {
                if Date().timeIntervalSince(stableSince) >= Double(quiet.components.seconds) + Double(quiet.components.attoseconds) / 1e18 { break }
            } else {
                last = signature
                stableSince = Date()
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(model.isPreviewIdle && model.thumbnailsSettled, "model did not settle within \(timeout) s")
        await model.refreshHistogramNow()
        try await Task.sleep(for: .milliseconds(150))
    }

    private static func signature(_ model: EditorModel) -> String {
        var tiles = 0
        for (_, image) in model.thumbnails { tiles ^= ObjectIdentifier(image).hashValue }
        return "\(model.presetThumbnails.count)|\(model.publishedFrames)|\(model.thumbnails.count)|\(tiles)|\(String(describing: model.latitudeReading))|\(model.hoverPreviewFilm?.id ?? "-")|\(model.latitudeSession.generation)"
    }
}
