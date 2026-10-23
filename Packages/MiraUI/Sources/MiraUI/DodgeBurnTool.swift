import Foundation
import MiraCore
import Observation

/// State of the dodge and burn brush tool. Strokes themselves live in `Recipe.dodgeBurn`; this holds
/// what the tool needs while it is open: the brush, the selection, the mask overlay and the stroke
/// being painted.
@MainActor
@Observable
public final class DodgeBurnToolState {
    /// The brush tool is on: drags on the canvas paint.
    public internal(set) var isActive = false
    /// The brush settings new strokes are made with (a stroke without points; its `id` is not used).
    public var brush = DodgeBurnStroke(mode: .dodge, size: 0.08, feather: 0.6, flow: 0.25, strength: 0.5,
                                       range: .midtones, protectTones: true, lumaRange: nil)
    /// The stroke whose settings the sliders edit, nil to edit the brush.
    public internal(set) var selectedStrokeID: UUID?
    /// Shows where the strokes apply as a red wash (key O). Only while the tool is open.
    public internal(set) var maskOverlay = false
    /// The stroke under the pointer right now. Rendered into the preview but not yet in the recipe.
    public internal(set) var liveStroke: DodgeBurnStroke?
    /// Dodge and burn are flipped while Option is held at the start of a stroke.
    public internal(set) var isFlipping = false

    public init() {}

    /// Smallest and largest brush the size keys reach (fraction of the short side).
    public static let sizeLimits = DodgeBurnStroke.sizeRange
}
