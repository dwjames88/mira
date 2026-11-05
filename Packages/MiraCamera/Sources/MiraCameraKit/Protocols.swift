import CoreGraphics
import Foundation
import MiraCore

/// Photos authorization as the camera cares about it.
public enum LibraryAccess: Sendable, Equatable {
    case full, limited, addOnly, denied, notDetermined
}

/// Errors from attaching a recipe to a saved asset.
public enum PrintError: Error, Sendable, Equatable {
    /// The asset was deleted before its print was made; the pending print is dropped.
    case assetMissing
    case failed(String)
}

/// Step 1 of the save: puts the capture in the Photos library. Implementations may move the files.
public protocol PhotoLibraryWriting: Sendable {
    func access() async -> LibraryAccess
    /// Creates an asset (photo = HEIC, alternate = DNG) and returns its local identifier.
    func createAsset(photo: URL, alternateRaw: URL?) async throws -> String
    /// Creates a plain asset from a baked JPEG (limited / add-only access) and returns its local identifier.
    func createBakedCopy(jpeg: URL) async throws -> String
}

/// Step 2 of the save: attaches the recipe as the asset's edit. Throws `PrintError.assetMissing` when the asset is gone.
public protocol PrintWriting: Sendable {
    func attach(recipe: Recipe, toAsset id: String, rawBase: Bool) async throws
}

/// Renders a JPEG with the recipe applied, for libraries where the edit cannot be attached.
public protocol PrintBaking: Sendable {
    func bake(recipe: Recipe, photo: URL, raw: URL?) async throws -> URL
}

/// The camera device as the UI drives it (no AVFoundation types).
public protocol CaptureDeviceControlling: Sendable {
    /// Sets exposure compensation; returns the value actually applied (clamped to the device).
    func setExposureBias(_ ev: Double) async -> Double
    func focusAndMeter(at point: CGPoint, lock: Bool) async
    func unlockFocusAndExposure() async
    func setWhiteBalance(_ state: WhiteBalanceState) async
    func setZoom(_ factor: Double, ramp: Bool) async
    func lenses() async -> [Lens]
    func capabilities() async -> CaptureCapabilities
}
