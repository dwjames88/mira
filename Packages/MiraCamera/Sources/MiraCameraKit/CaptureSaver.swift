import Foundation
import MiraCore

/// A capture as it comes off the photo output: temp files the saver takes over.
public struct CapturedFrame: Sendable, Equatable {
    public var heicURL: URL
    public var dngURL: URL?
    public var pixelSize: PixelSize
    /// Exposure time in seconds, if known.
    public var exposureTime: Double?
    /// Degrees the photo is turned clockwise to be upright (`videoRotationAngleForHorizonLevelCapture` as applied to the
    /// photo output): `pixelSize` is in sensor orientation, so 90 or 270 swap it. 90 = portrait phone.
    public var rotationAngle: Double

    public init(heicURL: URL, dngURL: URL? = nil, pixelSize: PixelSize, exposureTime: Double? = nil, rotationAngle: Double = 90) {
        self.rotationAngle = rotationAngle
        self.heicURL = heicURL
        self.dngURL = dngURL
        self.pixelSize = pixelSize
        self.exposureTime = exposureTime
    }
}

/// What `CaptureSaver.save` did.
public enum SaveOutcome: Sendable, Equatable {
    /// Saved, and the recipe is attached (re-editable).
    case developed(assetID: String)
    /// Saved; attaching the recipe failed and will be retried from the queue.
    case printPending(assetID: String)
    /// Limited or add-only access: the original plus a baked copy; the recipe is not attached.
    case bakedCopy(notice: String, originalAssetID: String, bakedAssetID: String)
    /// Limited or add-only access and baking failed: only the original was saved.
    case originalOnly(assetID: String, notice: String)

    public var assetID: String {
        switch self {
        case .developed(let id), .printPending(let id): id
        case .bakedCopy(_, let id, _): id
        case .originalOnly(let id, _): id
        }
    }

    /// The asset the user ends up with: the developed frame, the baked copy (not the plain original), or the original.
    public var savedAssetID: String {
        switch self {
        case .developed(let id), .printPending(let id): id
        case .bakedCopy(_, _, let baked): baked
        case .originalOnly(let id, _): id
        }
    }
}

public enum CaptureSaveError: Error, Sendable, Equatable {
    case photosAccessOff

    /// Mono caps copy for the viewfinder.
    public var monoCopy: String { "PHOTOS ACCESS IS OFF" }
}

/// The two-step save: asset first (the negative), recipe second (the print).
public actor CaptureSaver {
    public static let limitedAccessNotice = "Allow full Photos access to keep frames re-editable."
    /// Captures allowed between shutter and developed.
    public static let maxInFlight = 3

    private let library: any PhotoLibraryWriting
    private let baker: any PrintBaking
    private let queue: PrintQueue
    private var inFlight = 0

    /// Asset identifiers of developed frames (from the print queue and the baked path).
    public nonisolated var developedFrames: AsyncStream<String> { queue.developed }

    public init(library: any PhotoLibraryWriting, baker: any PrintBaking, queue: PrintQueue) {
        self.library = library
        self.baker = baker
        self.queue = queue
    }

    /// Frames between capture and developed (the "DEVELOPING n" count).
    public var developingCount: Int { inFlight }

    /// False while 3 or more frames are between capture and developed.
    public var canAcceptCapture: Bool { inFlight < Self.maxInFlight }

    /// Call when the shutter fires. Balanced by `save` (success or failure) or `captureFailed()`.
    public func captureStarted() { inFlight += 1 }

    /// Call when a capture produced no frame.
    public func captureFailed() { inFlight = max(0, inFlight - 1) }

    public func save(_ capture: CapturedFrame, recipe: Recipe) async throws -> SaveOutcome {
        defer { inFlight = max(0, inFlight - 1) }
        let access = await library.access()
        switch access {
        case .denied, .notDetermined:
            throw CaptureSaveError.photosAccessOff
        case .full:
            let id = try await library.createAsset(photo: capture.heicURL, alternateRaw: capture.dngURL)
            Self.deleteTemp(capture.heicURL, capture.dngURL)
            let rawBase = capture.dngURL != nil
            _ = try await queue.enqueue(assetID: id, recipe: recipe, rawBase: rawBase)
            await queue.drain()
            let stillPending = await queue.pending.contains { $0.assetID == id }
            return stillPending ? .printPending(assetID: id) : .developed(assetID: id)
        case .limited, .addOnly:
            // Bake before the library takes the files.
            let baked: URL
            do {
                baked = try await baker.bake(recipe: recipe, photo: capture.heicURL, raw: capture.dngURL)
            } catch {
                let id = try await library.createAsset(photo: capture.heicURL, alternateRaw: capture.dngURL)
                Self.deleteTemp(capture.heicURL, capture.dngURL)
                queue.announceDeveloped(id)
                return .originalOnly(assetID: id, notice: Self.limitedAccessNotice)
            }
            let original: String
            let copy: String
            do {
                original = try await library.createAsset(photo: capture.heicURL, alternateRaw: capture.dngURL)
                copy = try await library.createBakedCopy(jpeg: baked)
            } catch {
                // The library takes the baked file only when its asset is created; a failed step must not strand it.
                Self.deleteTemp(baked)
                throw error
            }
            Self.deleteTemp(capture.heicURL, capture.dngURL, baked)
            queue.announceDeveloped(copy)
            return .bakedCopy(notice: Self.limitedAccessNotice, originalAssetID: original, bakedAssetID: copy)
        }
    }

    /// Removes temp files after step 1 succeeded (the library moves or copies them; missing is fine).
    private static func deleteTemp(_ urls: URL?...) {
        for case let url? in urls { try? FileManager.default.removeItem(at: url) }
    }
}
