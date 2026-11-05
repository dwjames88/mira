#if os(iOS)
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import MiraCameraKit
import Synchronization

/// A location reduced to plain values so it can cross to the AVFoundation callback queue.
struct LocationSnapshot: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var timestamp: Date
    var horizontalAccuracy: Double?

    var gpsDictionary: [String: Any] {
        LocationMetadata.gpsDictionary(
            latitude: latitude, longitude: longitude, altitude: altitude, timestamp: timestamp,
            horizontalAccuracy: horizontalAccuracy)
    }
}

/// One capture request. AVFoundation calls it on its own queues; every callback is `nonisolated` (this is
/// not an actor) and only touches `state`, so it resumes the continuation exactly once and never touches the
/// controller's isolation. `@unchecked Sendable`: all mutable state sits behind the `Mutex`.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, AVCapturePhotoFileDataRepresentationCustomizer,
    @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<CapturedFrame, Error>?
        var heic: URL?
        var dng: URL?
        var size: PixelSize?
        var exposure: Double?
        var error: CaptureError?
    }

    private let state = Mutex(State())
    private let signals: AsyncStream<CaptureSignal>.Continuation
    private let location: LocationSnapshot?
    private let baseName = UUID().uuidString

    /// Temp folder for captures (crash-safe: the saver takes them from here).
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "MiraCamera", directoryHint: .isDirectory)
    }

    init(signals: AsyncStream<CaptureSignal>.Continuation, location: LocationSnapshot?) {
        self.signals = signals
        self.location = location
    }

    /// Call once, before `capturePhoto`.
    func begin(_ continuation: CheckedContinuation<CapturedFrame, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    // MARK: AVCapturePhotoCaptureDelegate (nonisolated: AVFoundation's queues)

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        signals.yield(.shutterClosed)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            state.withLock { $0.error = $0.error ?? .failed(error.localizedDescription) }
            return
        }
        let data = location == nil ? photo.fileDataRepresentation() : photo.fileDataRepresentation(with: self)
        guard let data else {
            state.withLock { $0.error = $0.error ?? .noProcessedPhoto }
            return
        }
        let isRaw = photo.isRawPhoto
        let url = Self.directory.appending(path: "\(baseName).\(isRaw ? "dng" : "heic")")
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            state.withLock { $0.error = $0.error ?? .failed(error.localizedDescription) }
            return
        }
        let dims = photo.resolvedSettings.photoDimensions
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let exposure = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        state.withLock {
            if isRaw {
                $0.dng = url
            } else {
                $0.heic = url
                $0.size = PixelSize(width: Int(dims.width), height: Int(dims.height))
            }
            if let exposure, exposure > 0 { $0.exposure = exposure }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        let outcome: (CheckedContinuation<CapturedFrame, Error>?, Result<CapturedFrame, CaptureError>, [URL]) = state.withLock {
            let continuation = $0.continuation
            $0.continuation = nil   // resumed exactly once
            let files = [$0.heic, $0.dng].compactMap { $0 }
            if let error { $0.error = $0.error ?? .failed(error.localizedDescription) }
            if let failure = $0.error { return (continuation, .failure(failure), files) }
            guard let heic = $0.heic, let size = $0.size else { return (continuation, .failure(.noProcessedPhoto), files) }
            return (continuation, .success(CapturedFrame(heicURL: heic, dngURL: $0.dng, pixelSize: size, exposureTime: $0.exposure)), [])
        }
        for url in outcome.2 { try? FileManager.default.removeItem(at: url) }
        outcome.0?.resume(with: outcome.1.mapError { $0 as Error })
    }

    // MARK: AVCapturePhotoFileDataRepresentationCustomizer

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let location else { return nil }
        var metadata = photo.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = location.gpsDictionary
        return metadata
    }
}
#endif
