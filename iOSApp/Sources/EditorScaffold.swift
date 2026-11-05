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

/// Equal-width 48pt tabs, hairline-underlined.
struct EditorTabBar: View {
    @Binding var tab: EditorTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach([(EditorTab.crop, "CROP"), (.films, "FILMS"), (.develop, "DEVELOP"), (.dodgeBurn, "DODGE & BURN")], id: \.0) { item in
                let selected = tab == item.0
                Button { tab = item.0 } label: {
                    Text(item.1)
                        .ffLabel(size: 11, color: selected ? T.paper : T.paperDim,
                                 weight: selected ? .medium : .regular)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? T.lichen : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The editor screen's vertical stack: header, photo, step bar, controls. Generic over the photo and
/// the controls so the layout can be rendered offscreen without the Metal preview.
struct EditorScaffold<Photo: View, Panel: View>: View {
    @Bindable var model: EditorViewModel
    @Binding var tab: EditorTab
    let onClose: () -> Void
    @ViewBuilder var photo: Photo
    @ViewBuilder var panel: Panel

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                EditorHeader(model: model, onClose: onClose)
                FFHairline()
                photo
                FFHairline()
                EditorTabBar(tab: $tab)
                FFHairline()
                panel
            }
        }
    }
}
