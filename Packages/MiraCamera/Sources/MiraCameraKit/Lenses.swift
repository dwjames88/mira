import Foundation

/// What the device reports about its (virtual) camera, mirrored without AVFoundation types.
public struct LensDescriptor: Sendable, Equatable, Codable {
    /// Horizontal field of view in degrees of the active format at zoom factor 1 of the device.
    public var fieldOfViewDegrees: Double
    /// Horizontal field of view of each constituent camera, widest first. Optional: when empty the
    /// constituents are derived by scaling `fieldOfViewDegrees` with their zoom factors.
    public var constituentFieldsOfView: [Double]
    /// `virtualDeviceSwitchOverVideoZoomFactors` (zoom factors where the next constituent takes over).
    public var switchOverZoomFactors: [Double]
    /// `displayVideoZoomFactorMultiplier` (0.5 on triple and dual-wide cameras, 1 on a single wide).
    public var displayZoomMultiplier: Double
    public var minZoom: Double
    public var maxZoom: Double
    /// Number of constituent cameras.
    public var constituentCount: Int

    public init(
        fieldOfViewDegrees: Double,
        constituentFieldsOfView: [Double] = [],
        switchOverZoomFactors: [Double] = [],
        displayZoomMultiplier: Double = 1,
        minZoom: Double = 1,
        maxZoom: Double = 1,
        constituentCount: Int = 1
    ) {
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.constituentFieldsOfView = constituentFieldsOfView
        self.switchOverZoomFactors = switchOverZoomFactors
        self.displayZoomMultiplier = displayZoomMultiplier
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.constituentCount = constituentCount
    }
}

/// One focal-length chip.
public struct Lens: Sendable, Equatable, Identifiable {
    /// 35 mm equivalent focal length, rounded.
    public var equivalentMM: Int
    /// The device `videoZoomFactor` that selects this lens.
    public var zoomFactor: Double
    /// True for the 2x crop of the main lens (no tele camera behind it).
    public var isCrop: Bool
    public var id: Int { equivalentMM }
    /// Chip text, millimeters only: "24".
    public var label: String { "\(equivalentMM)" }
    public var accessibilityLabel: String {
        isCrop ? "\(equivalentMM) millimeter, cropped from the main lens" : "\(equivalentMM) millimeter lens"
    }

    public init(equivalentMM: Int, zoomFactor: Double, isCrop: Bool) {
        self.equivalentMM = equivalentMM
        self.zoomFactor = zoomFactor
        self.isCrop = isCrop
    }
}

/// Focal lengths computed from field of view, never hard-coded per model.
public enum LensCatalog {
    /// Diagonal of a 35 mm frame, mm.
    static let fullFrameDiagonal = 43.27
    /// Below this equivalent a lens is the ultra-wide, not the main camera.
    static let mainLensMinimumMM = 18.0

    /// 35 mm equivalent focal length for a horizontal FOV on a 4:3 sensor (diagonal convention).
    public static func equivalentMM(horizontalFOVDegrees h: Double) -> Double {
        let halfH = h * .pi / 360
        let tanHalfDiag = tan(halfH) * (1.25)   // sqrt(4^2 + 3^2) / 4
        return fullFrameDiagonal / (2 * tanHalfDiag)
    }

    /// The chips for a device, ordered wide to long.
    public static func lenses(for d: LensDescriptor) -> [Lens] {
        guard d.fieldOfViewDegrees > 0 else { return [] }
        let count = max(1, d.constituentCount)
        let baseEq = equivalentMM(horizontalFOVDegrees: d.fieldOfViewDegrees)
        // Zoom factor of each constituent: the first is zoom 1 (the wide end of the device).
        var zooms: [Double] = [max(1, d.minZoom)]
        zooms += d.switchOverZoomFactors.prefix(count - 1)
        zooms = Array(zooms.prefix(count))
        let eqs: [Double] = zooms.indices.map { i in
            if d.constituentFieldsOfView.count == zooms.count, d.constituentFieldsOfView[i] > 0 {
                return equivalentMM(horizontalFOVDegrees: d.constituentFieldsOfView[i])
            }
            return baseEq * zooms[i] / zooms[0]
        }
        var lenses = zip(zooms, eqs).map { Lens(equivalentMM: Int($1.rounded()), zoomFactor: $0, isCrop: false) }

        // The 2x crop of the main lens, unless a tele camera sits close behind it.
        let main = eqs.firstIndex { $0 >= mainLensMinimumMM } ?? 0
        let cropEq = eqs[main] * 2
        let cropZoom = zooms[main] * 2
        let next = main + 1 < eqs.count ? eqs[main + 1] : nil
        if cropZoom <= d.maxZoom, next == nil || next! >= cropEq * 1.5 {
            lenses.insert(Lens(equivalentMM: Int(cropEq.rounded()), zoomFactor: cropZoom, isCrop: true), at: main + 1)
        }
        return lenses
    }

    /// Equivalent focal length at an arbitrary zoom factor (the pinch readout).
    public static func equivalent(atZoom zoom: Double, for d: LensDescriptor) -> Int {
        guard d.fieldOfViewDegrees > 0 else { return 0 }
        let count = max(1, d.constituentCount)
        var zooms: [Double] = [max(1, d.minZoom)]
        zooms += d.switchOverZoomFactors.prefix(count - 1)
        zooms = Array(zooms.prefix(count))
        let z = max(zoom, zooms[0])
        let i = zooms.lastIndex { $0 <= z } ?? 0
        let baseEq = equivalentMM(horizontalFOVDegrees: d.fieldOfViewDegrees)
        let eq: Double
        if d.constituentFieldsOfView.count == zooms.count, d.constituentFieldsOfView[i] > 0 {
            eq = equivalentMM(horizontalFOVDegrees: d.constituentFieldsOfView[i])
        } else {
            eq = baseEq * zooms[i] / zooms[0]
        }
        return Int((eq * z / zooms[i]).rounded())
    }

    /// The label the UI shows for a zoom factor in "x" terms ("1x" is the main lens on a triple camera).
    public static func displayZoom(_ zoom: Double, for d: LensDescriptor) -> Double { zoom * d.displayZoomMultiplier }
}
