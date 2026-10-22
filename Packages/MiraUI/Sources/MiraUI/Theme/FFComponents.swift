import AppKit
import SwiftUI

private typealias T = FieldFramesTheme

// MARK: Hairline

/// A 1 pt divider in the hair colour.
public struct FFHairline: View {
    public enum Axis: Sendable { case horizontal, vertical }
    private let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        switch axis {
        case .horizontal:
            Rectangle().fill(T.hair).frame(height: 1).accessibilityHidden(true)
        case .vertical:
            Rectangle().fill(T.hair).frame(width: 1).accessibilityHidden(true)
        }
    }
}

/// A section header: a mono label followed by a hairline that runs to the edge.
public struct FFSectionLabel: View {
    private let title: String
    private let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: T.cells(1)) {
            Text(title).ffLabel(color: T.paperDim)
            FFHairline()
            if let trailing { Text(trailing).ffLabel(color: T.paperDim) }
        }
        .frame(height: T.rows(1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Buttons

/// Button chrome: mono uppercase label, hairline border, 2 pt radius. Lichen when prominent.
public struct FFButtonStyle: ButtonStyle {
    public var prominent: Bool

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        FFButtonChrome(prominent: prominent, pressed: configuration.isPressed) { configuration.label }
    }
}

/// The drawn button, reusable for press-and-hold controls that cannot be a `Button`.
public struct FFButtonChrome<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    private let prominent: Bool
    private let pressed: Bool
    private let label: Label

    public init(prominent: Bool = false, pressed: Bool = false, @ViewBuilder label: () -> Label) {
        self.prominent = prominent
        self.pressed = pressed
        self.label = label()
    }

    public var body: some View {
        let accent = prominent || pressed
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        label
            .ffLabel(size: 10, color: accent ? T.lichen : (hovering ? T.paper : T.paperSoft), weight: .medium)
            .lineLimit(1)
            .padding(.horizontal, T.cells(2))
            .frame(minHeight: T.rows(2))
            .background(shape.fill(pressed ? T.lichen.opacity(0.14) : (hovering ? T.hair : Color.clear)))
            .overlay(shape.strokeBorder(accent ? T.lichen : (hovering ? T.paperDim : T.hair), lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// Chrome-less toolbar button: mono uppercase text, paperMid, paper on hover, lichen when prominent.
public struct FFToolbarButtonStyle: ButtonStyle {
    public var prominent: Bool

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        FFToolbarButtonLabel(prominent: prominent, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct FFToolbarButtonLabel<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let prominent: Bool
    let pressed: Bool
    @ViewBuilder let label: Label

    var body: some View {
        let color = isEnabled ? ((prominent || pressed || hovering) ? T.lichen : T.paperMid) : T.paperDim
        label
            .labelStyle(.titleOnly)
            .ffLabel(size: 11, color: color, weight: .medium)
            .lineLimit(1)
            .padding(.horizontal, T.cells(1))
            .frame(minHeight: T.rows(2))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

/// Chrome-less SF Symbol toolbar button: monochrome 17 pt, paperMid, paper on hover, lichen when
/// `active`, dimmed when disabled. Pair with `.help` and `.accessibilityLabel`.
public struct FFToolbarIconButtonStyle: ButtonStyle {
    public var active: Bool
    public var size: CGFloat

    public init(active: Bool = false, size: CGFloat = 17) {
        self.active = active
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        FFToolbarIconLabel(active: active, size: size, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct FFToolbarIconLabel<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let active: Bool
    let size: CGFloat
    let pressed: Bool
    @ViewBuilder let label: Label

    var body: some View {
        let color = isEnabled ? ((active || pressed) ? T.lichen : (hovering ? T.paper : T.paperMid)) : T.paperDim
        label
            .labelStyle(.iconOnly)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .frame(minWidth: T.rows(2), minHeight: T.rows(2))
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == FFToolbarIconButtonStyle {
    public static var ffToolbarIcon: FFToolbarIconButtonStyle { FFToolbarIconButtonStyle() }
    public static func ffToolbarIcon(active: Bool = false, size: CGFloat) -> FFToolbarIconButtonStyle { FFToolbarIconButtonStyle(active: active, size: size) }
    public static func ffToolbarIcon(active: Bool) -> FFToolbarIconButtonStyle { FFToolbarIconButtonStyle(active: active) }
}

extension ButtonStyle where Self == FFButtonStyle {
    public static var ff: FFButtonStyle { FFButtonStyle() }
    public static var ffProminent: FFButtonStyle { FFButtonStyle(prominent: true) }
}

extension ButtonStyle where Self == FFToolbarButtonStyle {
    public static var ffToolbar: FFToolbarButtonStyle { FFToolbarButtonStyle() }
    public static var ffToolbarProminent: FFToolbarButtonStyle { FFToolbarButtonStyle(prominent: true) }}

// MARK: Toggle

/// A mono label with a square check box; lichen when on.
public struct FFToggle: View {
    private let title: String
    @Binding private var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: T.cells(1)) {
                ZStack {
                    Rectangle().strokeBorder(isOn ? T.lichen : T.paperDim, lineWidth: 1)
                    if isOn { Rectangle().fill(T.lichen).padding(3) }
                }
                .frame(width: 10, height: 10)
                Text(title).ffLabel(color: isOn ? T.paper : T.paperDim)
                Spacer(minLength: 0)
            }
            .frame(height: T.rows(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: Tab bar

/// A row of mono uppercase labels; the selected one is paper with a lichen underline.
public struct FFTabBar<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    @Binding private var selection: Value

    public init(_ options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: T.cells(3)) {
            ForEach(options.indices, id: \.self) { i in
                let selected = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].title)
                        .ffLabel(color: selected ? T.paper : T.paperDim, weight: selected ? .medium : .regular)
                        .lineLimit(1)
                        .frame(height: T.rows(2))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? T.lichen : Color.clear).frame(height: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Slider

/// A thin, drawn slider: a 2 pt hair-coloured track, a lichen fill from the zero point (or the minimum),
/// a small square thumb and a mono readout. Drag or click to set; arrow keys and VoiceOver adjust.
/// Double-click the label to reset to `defaultValue`.
public struct FFSlider: View {
    private let label: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let defaultValue: Double
    private let decimals: Int

    @FocusState private var focused: Bool
    @State private var dragging = false
    @State private var hovering = false

    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
                default defaultValue: Double, decimals: Int = 2) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.decimals = decimals
    }

    private var span: Double { range.upperBound - range.lowerBound }
    private func fraction(_ v: Double) -> Double { span > 0 ? min(1, max(0, (v - range.lowerBound) / span)) : 0 }
    /// The fill starts at zero when the range straddles it, otherwise at the minimum.
    private var origin: Double { range.lowerBound < 0 && range.upperBound > 0 ? 0 : range.lowerBound }
    private var readout: String { value.formatted(.number.precision(.fractionLength(decimals))) }
    private var step: Double { span / 20 }

    private func set(_ v: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, v))
        let rounded = (clamped * 100).rounded() / 100
        if rounded != value { value = rounded }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .ffLabel(color: dragging || focused ? T.paper : T.paperDim)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { set(defaultValue) }
                    .help("Double-click to reset")
                Spacer(minLength: 0)
                Text(readout)
                    .font(T.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(value == defaultValue ? T.paperDim : T.paper)
            }
            .frame(height: T.rows(1))
            track
                .frame(height: T.rows(1))
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset") { set(defaultValue) }
    }

    private var track: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 8
            let usable = max(1, geo.size.width - thumb)
            let x = { (v: Double) in thumb / 2 + usable * fraction(v) }
            let a = x(origin), b = x(value)
            ZStack(alignment: .leading) {
                Rectangle().fill(T.hair).frame(height: 2)
                Rectangle().fill(T.lichen)
                    .frame(width: abs(b - a), height: 2)
                    .offset(x: min(a, b))
                // Tick at the default position.
                Rectangle().fill(T.paperDim.opacity(0.6)).frame(width: 1, height: 6)
                    .offset(x: x(defaultValue) - 0.5)
                Rectangle()
                    .fill(dragging || focused ? T.lichen : (hovering ? T.paper : T.paperSoft))
                    .frame(width: thumb, height: thumb)
                    .offset(x: b - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        focused = true
                        set(range.lowerBound + span * min(1, max(0, (g.location.x - thumb / 2) / usable)))
                    }
                    .onEnded { _ in dragging = false })
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { set(value - step / 5); return .handled }
        .onKeyPress(.rightArrow) { set(value + step / 5); return .handled }
        .onKeyPress(.downArrow) { set(value - step / 5); return .handled }
        .onKeyPress(.upArrow) { set(value + step / 5); return .handled }
    }
}

// MARK: Film card

/// A film tile: thumbnail, film name in Cormorant, brand and ISO in mono. Selected gets a lichen hairline.
public struct FilmCard: View {
    public static let width: CGFloat = T.cells(14)
    public static let thumbnailHeight: CGFloat = T.rows(5)

    private let title: Text
    private let accessibilityTitle: String
    private let titleLines: Int
    private let caption: String
    private let captionTint: Color?
    private let image: NSImage?
    private let isSelected: Bool
    private let action: () -> Void
    private let onHoverChange: ((Bool) -> Void)?
    @State private var hovering = false

    public init(title: String, caption: String, image: NSImage?, isSelected: Bool,
                onHoverChange: ((Bool) -> Void)? = nil, action: @escaping () -> Void) {
        self.init(styledTitle: Text(title), accessibilityTitle: title, titleLines: 1, caption: caption,
                  captionTint: nil, image: image, isSelected: isSelected, onHoverChange: onHoverChange, action: action)
    }

    /// A card whose title is a styled `Text` (segments may set their own colour or font) over up to
    /// `titleLines` lines, with an optional caption colour (a warning mark). Everything else is the film card.
    public init(styledTitle: Text, accessibilityTitle: String, titleLines: Int, caption: String,
                captionTint: Color?, image: NSImage?, isSelected: Bool,
                onHoverChange: ((Bool) -> Void)? = nil, action: @escaping () -> Void) {
        self.onHoverChange = onHoverChange
        self.title = styledTitle
        self.accessibilityTitle = accessibilityTitle
        self.titleLines = titleLines
        self.caption = caption
        self.captionTint = captionTint
        self.image = image
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(T.hair)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: Self.width, height: Self.thumbnailHeight)
                .clipped()
                title
                    .font(T.display(16, weight: .medium))
                    .foregroundStyle(isSelected ? T.paper : T.paperSoft)
                    .lineLimit(titleLines)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6)
                    .frame(width: Self.width, alignment: .leading)
                    .frame(minHeight: titleLines > 1 ? T.rows(2.5) : nil, alignment: .topLeading)
                Text(caption)
                    .ffLabel(size: 9, color: captionTint ?? (isSelected ? T.lichen : T.paperDim))
                    .lineLimit(1)
                    .frame(width: Self.width, height: T.rows(1), alignment: .leading)
            }
            .padding(4)
            .overlay(Rectangle().strokeBorder(isSelected ? T.lichen : (hovering ? T.hair : Color.clear), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; onHoverChange?($0) }
        .accessibilityLabel("\(accessibilityTitle), \(caption)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Panel

/// A panel ground: ink-soft with grain. Use as a background.
public struct FFPanelBackground: View {
    public init() {}

    public var body: some View {
        FFGroundBackground(base: T.inkSoft, grain: 0.07)
    }
}

/// A container on the panel ground.
public struct FFPanel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.background { FFPanelBackground() }
    }
}

extension View {
    /// Puts the view on the panel ground (ink-soft with grain).
    public func ffPanel() -> some View {
        background { FFPanelBackground() }
    }
}

// MARK: Byline

/// "Software by FieldFrames" in the house mono label style.
public struct FFByline: View {
    public init() {}

    public var body: some View {
        Text("Software by FieldFrames").ffLabel(size: 10, color: T.paperDim)
    }
}

// MARK: Empty state

/// A quiet empty state: Cormorant headline, mono sub-label, one button.
public struct FFEmptyState: View {
    private let title: String
    private let subtitle: String
    private let buttonTitle: String?
    private let note: String?
    private let action: () -> Void

    public init(title: String, subtitle: String, buttonTitle: String? = nil, note: String? = nil,
                action: @escaping () -> Void = {}) {
        self.title = title
        self.subtitle = subtitle
        self.buttonTitle = buttonTitle
        self.note = note
        self.action = action
    }

    public var body: some View {
        VStack(spacing: T.rows(1)) {
            Text(title)
                .font(T.display(52, weight: .regular))
                .foregroundStyle(T.paper)
            FFByline()
            Text(subtitle).ffLabel(size: 11)
            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .buttonStyle(FFButtonStyle(prominent: true))
                    .padding(.top, T.rows(1))
            }
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(T.paperDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: T.cells(48))
                    .padding(.top, T.rows(2))
            }
        }
        .padding(T.cells(5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Scrolling

private struct FFInlineScrollKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// When true, `FFScrollView` lays its content out inline instead of scrolling. `ImageRenderer` cannot
    /// draw AppKit-backed scroll views, so the headless snapshot tests set this.
    var ffInlineScroll: Bool {
        get { self[FFInlineScrollKey.self] }
        set { self[FFInlineScrollKey.self] = newValue }
    }
}

/// A `ScrollView` that can be flattened for headless rendering.
struct FFScrollView<Content: View>: View {
    @Environment(\.ffInlineScroll) private var inline
    let axes: Axis.Set
    let content: Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        if inline {
            Color.clear
                .overlay(alignment: .topLeading) {
                    content.fixedSize(horizontal: axes.contains(.horizontal), vertical: axes.contains(.vertical))
                }
                .clipped()
        } else {
            ScrollView(axes) { content }
        }
    }
}
