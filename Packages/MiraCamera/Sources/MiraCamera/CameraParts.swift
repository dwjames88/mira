#if os(iOS)
import MiraCameraKit
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

// MARK: Header

/// The editor header's pattern: chevron + LIBRARY (11 pt mono, 44 pt hit), the film name centered in Cormorant,
/// the counter slot ("DEVELOPING n") and a small settings gear, 48 pt tall.
struct CameraHeader: View {
    let filmName: String?
    let developing: Int
    let onBack: () -> Void
    let onSettings: () -> Void
    var showsFilmName = true

    var body: some View {
        HStack(spacing: T.cells(1)) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("LIBRARY").ffLabel(size: 11)
                }
                .foregroundStyle(T.paper)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to library")
            .accessibilityIdentifier("camera.library")
            Spacer(minLength: 0)
            if developing > 0 {
                Text("DEVELOPING \(developing)").ffLabel(size: 9, color: T.paperDim).lineLimit(1)
                    .accessibilityLabel("Developing \(developing) \(developing == 1 ? "frame" : "frames")")
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .light))
                    .foregroundStyle(T.paperMid)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera settings")
        }
        .padding(.leading, T.cells(2))
        .padding(.trailing, T.cells(0.5))
        .frame(height: 48)
        .overlay {
            if showsFilmName, let filmName, !filmName.isEmpty {
                Text(filmName)
                    .font(T.display(19, weight: .regular))
                    .foregroundStyle(T.paper)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: 110)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Film: \(filmName)")
            }
        }
    }
}

// MARK: Meter

/// Needle on a -3...+3 mono scale with a lichen centre tick (a 15 pt strip, no numerals), and the readout row under it.
struct MeterView: View {
    static let scaleHeight: CGFloat = 15

    let needle: Double
    let readout: String
    let latitude: LatitudeReadout
    /// Two rows (exposure, then latitude) for a narrow column.
    var stacked = false

    var body: some View {
        VStack(spacing: 2) {
            scale.frame(height: Self.scaleHeight)
            readoutRow
        }
        .padding(.horizontal, T.cells(2))
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light meter")
        .accessibilityValue("\(readout). \(latitude.text)")
    }

    private var scale: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { ev in w * CGFloat((ev + 3) / 6) }
            ZStack(alignment: .topLeading) {
                ForEach(-9...9, id: \.self) { third in
                    let ev = Double(third) / 3
                    let whole = third % 3 == 0
                    let height: CGFloat = third == 0 ? 9 : (whole ? 6 : 3.5)
                    Rectangle()
                        .fill(third == 0 ? T.lichen : (whole ? T.paperMid : T.paperDim))
                        .frame(width: third == 0 ? 2 : 1, height: height)
                        .position(x: x(ev), y: Self.scaleHeight - height / 2)
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(T.paper)
                    .position(x: x(needle * 3), y: 3)
                    .animation(.easeOut(duration: 0.15), value: needle)
            }
        }
    }

    private var readoutRow: some View {
        let parts = latitude.text.components(separatedBy: " \u{00B7} ")
        let latitudeRow = HStack(spacing: T.cells(1)) {
            Text(parts.first ?? "").ffLabel(size: 9, color: latitude.underIsHot ? T.paper : T.paperDim)
            Text("\u{00B7}").ffLabel(size: 9, color: T.paperDim)
            Text(parts.count > 1 ? parts[1] : "").ffLabel(size: 9, color: latitude.overIsHot ? T.paper : T.paperDim)
        }
        if stacked {
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                Text(readout).ffLabel(size: 9, color: T.paperDim).lineLimit(1)
                latitudeRow
            }.frame(maxWidth: .infinity, alignment: .leading))
        }
        return AnyView(HStack(spacing: T.cells(1)) {
            Text(readout).ffLabel(size: 9, color: T.paperDim).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(parts.first ?? "").ffLabel(size: 9, color: latitude.underIsHot ? T.paper : T.paperDim)
            Text("\u{00B7}").ffLabel(size: 9, color: T.paperDim)
            Text(parts.count > 1 ? parts[1] : "").ffLabel(size: 9, color: latitude.overIsHot ? T.paper : T.paperDim)
        }
        .lineLimit(1))
    }
}

// MARK: Lens chips

struct LensChips: View {
    let lenses: [Lens]
    let selected: Lens?
    let onSelect: (Lens) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(lenses) { lens in
                let on = lens.id == selected?.id
                Button { onSelect(lens) } label: {
                    Text(lens.label).ffLabel(size: 12, color: on ? T.paper : T.paperDim, weight: on ? .medium : .regular)
                        .frame(minWidth: 44, minHeight: 32)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? T.lichen : .clear).frame(width: 18, height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityLabel(for: lens, in: lenses))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    static func accessibilityLabel(for lens: Lens, in lenses: [Lens]) -> String {
        guard lens.isCrop else { return "\(lens.equivalentMM) millimeter" }
        let source = lenses.first { !$0.isCrop && abs($0.zoomFactor * 2 - lens.zoomFactor) < 0.01 }?.equivalentMM ?? lens.equivalentMM / 2
        return "\(lens.equivalentMM) millimeter, crop of \(source)"
    }
}

// MARK: EV dial

/// A window of thirds around the current value, dragged horizontally (drag left for more light). One selection
/// haptic per third (fired by the model). Tap the centre to return to 0.
struct EVDial: View {
    let value: Double
    let onChange: (Double) -> Void
    @State private var dragBase: Double?

    private let slot: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let visible = max(5, min(7, (Int((geo.size.width - 44) / slot) / 2) * 2 + 1))
            let half = visible / 2
            HStack(spacing: 0) {
                ForEach(-half...half, id: \.self) { i in
                    cell(i, value: ExposureModel.snapToThird(value) + Double(i) / 3)
                }
                Text("EV").ffLabel(size: 9, color: T.paperDim).frame(width: 36)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        let base = dragBase ?? ExposureModel.snapToThird(value)
                        dragBase = base
                        let steps = (-drag.translation.width / slot).rounded()
                        onChange(base + Double(steps) / 3)
                    }
                    .onEnded { _ in dragBase = nil })
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue("\(ExposureModel.label(value)) EV")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + ExposureModel.step)
            case .decrement: onChange(value - ExposureModel.step)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private func cell(_ i: Int, value v: Double) -> some View {
        let inRange = v >= ExposureModel.minEV - 0.001 && v <= ExposureModel.maxEV + 0.001
        ZStack {
            if inRange {
                Text(ExposureModel.label(v))
                    .ffLabel(size: i == 0 ? 13 : 11, color: i == 0 ? T.paper : T.paperDim, weight: i == 0 ? .medium : .regular)
                    .fixedSize()
            }
            if i == 0 {
                Rectangle().stroke(T.hair, lineWidth: 1).frame(width: slot - 4, height: 28)
                Rectangle().fill(T.lichen).frame(width: 16, height: 2).offset(y: 12)
            }
        }
        .frame(width: slot, height: 40)
        .contentShape(Rectangle())
        .onTapGesture { if i == 0 { onChange(0) } }
    }
}

// MARK: White balance dial

/// The white balance row, beside the EV dial's visual language: a hairline-boxed centre readout with a lichen
/// tick, a Kelvin ruler dragged horizontally (100 K per `pointsPerStep`, a tick every 100 K, a label every
/// 500 K), AUTO on the left (lichen when auto; tap toggles) and the unit on the right.
struct WBDial: View {
    /// nil is AUTO.
    let kelvin: Int?
    /// A live value while dragging (nil is AUTO).
    let onChange: (Int?) -> Void
    /// The drag ended: snap to a nearby preset.
    let onCommit: () -> Void
    let onToggleAuto: () -> Void
    @State private var dragBase: Int?

    private let pointsPerStep: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleAuto) {
                Text("AUTO").ffLabel(size: 9, color: kelvin == nil ? T.lichen : T.paperDim)
                    .frame(width: 52, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto white balance")
            .accessibilityValue(kelvin == nil ? "On" : "Off")
            ruler
            Text("K").ffLabel(size: 9, color: T.paperDim).frame(width: 36)
        }
        .frame(height: 40)
    }

    private var ruler: some View {
        GeometryReader { geo in
            let center = Double(kelvin ?? WhiteBalanceModel.startKelvin)
            let perK = Double(pointsPerStep) / Double(WhiteBalanceModel.step)
            let halfSpan = Int(geo.size.width / 2 / pointsPerStep) + 1
            ZStack {
                // Ticks every 100 K; labels every 500 K, hidden under the readout.
                ForEach(-halfSpan...halfSpan, id: \.self) { i in
                    let k = (Int(center) / WhiteBalanceModel.step + i) * WhiteBalanceModel.step
                    if WhiteBalanceModel.range.contains(k) {
                        let x = (Double(k) - center) * perK
                        let major = k % 500 == 0
                        Rectangle().fill(major ? T.paperDim : T.hair)
                            .frame(width: 1, height: major ? 8 : 4)
                            .offset(x: x, y: 14)
                        if major, abs(x) > 34 {
                            Text("\(k)").ffLabel(size: 9, color: T.paperDim).fixedSize()
                                .offset(x: x, y: -9)
                        }
                    }
                }
                .opacity(kelvin == nil ? 0.4 : 1)
                Rectangle().stroke(T.hair, lineWidth: 1).frame(width: 118, height: 22).offset(y: -9)
                Text(readout).ffLabel(size: 11, color: kelvin == nil ? T.paperDim : T.paper, weight: .medium)
                    .fixedSize().offset(y: -9)
                Rectangle().fill(T.lichen).frame(width: 16, height: 2).offset(y: 17)
            }
            .frame(width: geo.size.width, height: 40)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        let base = dragBase ?? (kelvin ?? WhiteBalanceModel.startKelvin)
                        dragBase = base
                        let steps = Int((-drag.translation.width / pointsPerStep).rounded())
                        onChange(WhiteBalanceModel.clamp(base + steps * WhiteBalanceModel.step))
                    }
                    .onEnded { _ in
                        dragBase = nil
                        onCommit()
                    })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("White balance")
        .accessibilityValue(kelvin.map { "\($0) Kelvin" } ?? "Auto")
        .accessibilityAdjustableAction { direction in
            let current = kelvin ?? WhiteBalanceModel.startKelvin
            switch direction {
            case .increment: onChange(WhiteBalanceModel.clamp(current + WhiteBalanceModel.step))
            case .decrement: onChange(WhiteBalanceModel.clamp(current - WhiteBalanceModel.step))
            @unknown default: break
            }
        }
    }

    private var readout: String {
        guard let kelvin else { return "\u{2014}" }
        return WhiteBalanceModel.preset(at: kelvin).map { "\(kelvin) \u{00B7} \($0.name)" } ?? "\(kelvin)"
    }
}

// MARK: Shutter

/// 72 pt ring, 1.5 pt paper hairline, ink fill; lichen for 120 ms on press; paperDim when it cannot take a press.
struct ShutterButtonStyle: ButtonStyle {
    let dimmed: Bool

    func makeBody(configuration: Configuration) -> some View {
        Circle()
            .fill(configuration.isPressed ? T.lichen : T.inkAlways)
            .overlay(Circle().strokeBorder(dimmed ? T.paperDim : T.paper, lineWidth: 1.5))
            .frame(width: 72, height: 72)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct ShutterButton: View {
    let readiness: ShutterReadiness
    let action: () -> Void

    var body: some View {
        Button(action: action) { Color.clear }
            .buttonStyle(ShutterButtonStyle(dimmed: readiness.dimsShutter))
            .frame(width: 72, height: 72)
            .disabled(readiness.dimsShutter)
            .accessibilityLabel("Take picture")
    }
}

// MARK: Last frame and doors

struct LastFrameThumb: View {
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(T.inkSoft)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: 16, weight: .light)).foregroundStyle(T.paperDim)
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .overlay(Rectangle().stroke(T.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the library")
        .accessibilityIdentifier("camera.lastFrame")
    }
}

struct DoorButton: View {
    let title: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) \u{25B8}").ffLabel(size: 11, color: T.paper)
                .frame(minWidth: 64, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: Over the finder

struct FocusMark: View {
    let point: CGPoint
    let locked: Bool
    let bounds: CGSize

    var body: some View {
        ZStack {
            Rectangle().stroke(T.onPhoto, lineWidth: 1).frame(width: 44, height: 44).position(point)
            if locked {
                Text("AE\u{00B7}AF LOCK").ffLabel(size: 9, color: T.onPhotoAccent)
                    .fixedSize()
                    .position(x: min(max(point.x, 40), max(40, bounds.width - 40)), y: min(point.y + 38, bounds.height - 12))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A mono caption on the finder's veil (notice line, pinch readout, original marker).
struct FinderCaption: View {
    let text: String
    var color: Color = T.onPhoto

    var body: some View {
        Text(text).ffLabel(size: 9, color: color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(T.onPhotoVeil)
            .allowsHitTesting(false)
    }
}
#endif
