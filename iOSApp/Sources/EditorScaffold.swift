import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// Back affordance (chevron + LIBRARY) on the left, status in the middle, Save state on the right.
struct EditorHeader: View {
    @Bindable var model: EditorViewModel
    let onClose: () -> Void
    @State private var confirmClose = false

    var body: some View {
        HStack(spacing: T.cells(1)) {
            Button {
                if model.hasUnsavedEdits { confirmClose = true } else { onClose() }
            } label: {
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
            Spacer(minLength: 0)
            Text(model.status).ffLabel(size: 9, color: T.paperDim).lineLimit(1)
            saveButton
        }
        .padding(.horizontal, T.cells(2))
        .frame(height: 48)
        .confirmationDialog("Discard unsaved edits?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard and go back", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    /// UNSAVED = prominent lichen SAVE; SAVING = inert; SAVED = dim, inert.
    @ViewBuilder private var saveButton: some View {
        switch model.saveState {
        case .unsaved:
            Button { Task { await model.save() } } label: {
                Text(model.saveTitle).padding(.vertical, 6).frame(minWidth: 44)
            }
            .buttonStyle(.ffProminent)
            .disabled(!model.hasPhoto)
        case .saving:
            Text(model.saveTitle).ffLabel(size: 10, color: T.paperMid, weight: .medium)
                .padding(.horizontal, T.cells(2)).frame(minHeight: 44)
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                Text(model.saveTitle).ffLabel(size: 10, color: T.paperDim)
            }
            .foregroundStyle(T.paperDim)
            .padding(.horizontal, T.cells(1)).frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Step bar

extension EditorTab {
    var title: String {
        switch self {
        case .crop: "Crop"
        case .films: "Films"
        case .develop: "Develop"
        case .dodgeBurn: "Dodge & Burn"
        }
    }

    /// Monoline SF Symbol for the step bar.
    var symbol: String {
        switch self {
        case .crop: "crop"
        case .films: "film"
        case .develop: "slider.horizontal.3"
        case .dodgeBurn: "paintbrush.pointed"
        }
    }
}

/// Four icons that fit every iPhone width; the selected step is paper with the lichen underline.
struct EditorStepBar: View {
    @Binding var tab: EditorTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorTab.allCases, id: \.self) { step in
                let selected = tab == step
                Button { tab = step } label: {
                    Image(systemName: step.symbol)
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(selected ? T.paper : T.paperDim)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? T.lichen : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(step.title)
            }
        }
    }
}

// MARK: Layout facts

/// Frames (in the scaffold's coordinate space) of the parts a layout test cares about.
struct EditorFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Publishes this view's frame under `id`, relative to the editor scaffold.
    func reportFrame(_ id: String) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: EditorFrameKey.self, value: [id: geo.frame(in: .named(EditorScaffoldSpace.name))])
            }
        }
    }
}

enum EditorScaffoldSpace { static let name = "editorScaffold" }

private struct PanelMaxHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 320 }

extension EnvironmentValues {
    /// The most height the control panel may take, so the photo always keeps the rest.
    var panelMaxHeight: CGFloat {
        get { self[PanelMaxHeightKey.self] }
        set { self[PanelMaxHeightKey.self] = newValue }
    }
}

/// Shows its content at its natural height, or scrolls it when the panel cap is smaller.
struct CappedScroll<Content: View>: View {
    var reserve: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.panelMaxHeight) private var cap

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: max(80, cap - reserve))
    }
}

// MARK: Panel dock

/// Fold control on the panel's top edge: tap, or drag down to hide the panel and up to bring it back.
struct PanelHandle: View {
    @Binding var hidden: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { hidden.toggle() }
        } label: {
            Image(systemName: hidden ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(T.paperMid)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 14).onEnded { g in
                withAnimation(.snappy(duration: 0.22)) {
                    if g.translation.height > 16 { hidden = true } else if g.translation.height < -16 { hidden = false }
                }
            })
        .accessibilityLabel(hidden ? "Show controls" : "Hide controls")
    }
}

/// The editor screen's vertical stack: header, step bar, photo, controls. Generic over the photo and
/// the controls so the layout can be rendered offscreen without the Metal preview. The panel sits
/// under the photo and never over it: the photo takes whatever height the panel leaves.
struct EditorScaffold<Photo: View, Panel: View>: View {
    @Bindable var model: EditorViewModel
    @Binding var tab: EditorTab
    let onClose: () -> Void
    var onLayout: (@MainActor @Sendable ([String: CGRect]) -> Void)?
    @ViewBuilder var photo: Photo
    @ViewBuilder var panel: Panel

    private var hidden: Binding<Bool> {
        Binding(get: { model.panelHidden[tab] ?? false }, set: { model.panelHidden[tab] = $0 })
    }

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            GeometryReader { geo in
                VStack(spacing: 0) {
                    EditorHeader(model: model, onClose: onClose)
                    FFHairline()
                    EditorStepBar(tab: $tab).reportFrame("stepBar")
                    FFHairline()
                    photo.frame(maxWidth: .infinity, maxHeight: .infinity).reportFrame("photo").clipped()
                    FFHairline()
                    VStack(spacing: 0) {
                        PanelHandle(hidden: hidden)
                        if !hidden.wrappedValue { panel.transition(.opacity) }
                    }
                    .ffPanel()
                    .reportFrame("panel")
                    .layoutPriority(1)
                }
                .environment(\.panelMaxHeight, geo.size.height * 0.5 - 32)
            }
        }
        .coordinateSpace(name: EditorScaffoldSpace.name)
        .onPreferenceChange(EditorFrameKey.self) { frames in
            MainActor.assumeIsolated { onLayout?(frames) }
        }
    }
}
