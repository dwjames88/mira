import Foundation
import UniformTypeIdentifiers

// MARK: - Which PhotoKit resource is the RAW

/// The kind of a `PHAssetResource`, reduced to what RAW selection needs. A protocol over plain fields
/// (not `PHAssetResource` itself) so the selection is testable without a photo library.
public enum AssetResourceKind: Sendable, Equatable {
    case photo, alternatePhoto, fullSizePhoto, other
}

public protocol AssetResourceFields {
    var resourceKind: AssetResourceKind { get }
    /// `PHAssetResource.uniformTypeIdentifier`.
    var typeIdentifier: String { get }
}

/// A plain value for tests and callers that already extracted the fields.
public struct AssetResourceInfo: AssetResourceFields, Equatable, Sendable {
    public var resourceKind: AssetResourceKind
    public var typeIdentifier: String
    public init(kind: AssetResourceKind, typeIdentifier: String) {
        self.resourceKind = kind
        self.typeIdentifier = typeIdentifier
    }
}

public enum RawResourceSelection {
    /// Index of the RAW original among `resources`, or nil when the asset has none.
    ///
    /// A RAW is a `.photo` (RAW-only assets, or a pair whose RAW was made the original with "Use RAW as
    /// original") or an `.alternatePhoto` (the RAW half of a RAW+JPEG pair) whose type conforms to
    /// `public.camera-raw-image`. The rendered edit (`.fullSizePhoto`) is never a candidate. When both a
    /// `.photo` and an `.alternatePhoto` are RAW, the `.photo` wins.
    public static func rawIndex(in resources: [some AssetResourceFields]) -> Int? {
        func isRaw(_ r: some AssetResourceFields) -> Bool {
            guard let type = UTType(r.typeIdentifier) else { return false }
            return type.conforms(to: .rawImage)
        }
        if let i = resources.firstIndex(where: { $0.resourceKind == .photo && isRaw($0) }) { return i }
        return resources.firstIndex(where: { $0.resourceKind == .alternatePhoto && isRaw($0) })
    }
}

// MARK: - Whether to open that RAW

/// What the asset carries in the way of adjustments.
public enum AssetAdjustmentState: Equatable, Sendable {
    case none
    /// Our adjustment data. `rawBase` is true when the edit was made on the RAW (see `MiraAdjustment.isRawBase`).
    case mira(rawBase: Bool)
    /// Another app's (Photos' own included).
    case foreign
}

/// Why the rendered file is used even though a RAW exists.
public enum RawFallbackReason: Equatable, Sendable {
    /// No RAW resource.
    case noRaw
    /// Another app's adjustments: Photos hands over their rendered output, not an original, so there is
    /// no pre-edit RAW state to continue from. Keep the rendered picture.
    case foreignAdjustments
    /// An edit saved by an earlier Mira build, made on the rendered JPEG. Re-basing it on the RAW would
    /// change how it looks, so it keeps its JPEG base.
    case earlierEditOnRenderedFile
}

public enum RawOpenPlan: Equatable, Sendable {
    /// `PHContentEditingInput.fullSizeImageURL` is already the RAW.
    case useInput
    /// Download the RAW resource and develop it; the editing input remains the base for the saved output.
    case fetchResource
    /// Our RAW-based edit, but there is no RAW to rebuild it on.
    case rawBaseMissing
    case keepRendered(RawFallbackReason)
}

public enum RawOpenPolicy {
    public static func plan(inputIsRAW: Bool, adjustments: AssetAdjustmentState, hasRawResource: Bool) -> RawOpenPlan {
        if inputIsRAW { return .useInput }
        switch adjustments {
        case .foreign: return .keepRendered(.foreignAdjustments)
        case .mira(rawBase: false): return .keepRendered(.earlierEditOnRenderedFile)
        case .mira(rawBase: true): return hasRawResource ? .fetchResource : .rawBaseMissing
        case .none: return hasRawResource ? .fetchResource : .keepRendered(.noRaw)
        }
    }
}
