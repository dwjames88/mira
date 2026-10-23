import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// SAVE PRESET / RENAME: the film name is a fixed prefix, the nickname a text field, and the final
/// name ("Portra 400 - Last Summer") is previewed live. Laid out like the app's Export sheet.
struct SavePresetSheet: View {
    @Bindable var model: EditorModel
    let mode: PresetSheetMode
    @State private var nickname: String
    @State private var error: String?
    @FocusState private var focused: Bool
    /// Headless snapshots cannot draw the AppKit text field; they show the typed text instead.
    @Environment(\.ffInlineScroll) private var snapshot

    init(model: EditorModel, mode: PresetSheetMode, initialNickname: String = "") {
        self.model = model
        self.mode = mode
        _nickname = State(initialValue: initialNickname)
    }

    private var renaming: UUID? {
        if case .rename(let id) = mode { return id }
        return nil
    }

    private var filmName: String {
        if let id = renaming, let p = model.presetStore.preset(id: id) { return p.filmName }
        return model.currentFilmName
    }

    /// Shown under the name so nobody expects a preset to carry the photo's brushwork.
    static let keepsNote = "Presets keep the film and develop settings; dodge & burn strokes stay with the photo."

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: T.rows(1)) {
            Text(renaming == nil ? "Save Preset" : "Rename Preset")
                .font(T.display(30, weight: .medium))
            FFHairline()
            FFSectionLabel("Film")
            Text(filmName)
                .font(T.display(21, weight: .medium))
                .foregroundStyle(T.paperSoft)
                .accessibilityLabel("Film \(filmName)")
            FFSectionLabel("Nickname")
            nicknameField
            FFSectionLabel("Preset name")
            Group {
                if canSave {
                    PresetText.name(film: filmName, nickname: trimmed, size: 21)
                        .font(T.display(21, weight: .medium))
                        .foregroundStyle(T.paper)
                } else {
                    Text("Type a nickname to name this preset")
                        .ffLabel(color: T.paperDim)
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: T.rows(2), alignment: .leading)
            .accessibilityLabel(canSave ? Preset.displayName(filmName: filmName, nickname: trimmed) : "No name yet")
            Text(Self.keepsNote)
                .ffLabel(size: 9, color: T.paperDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error {
                Text(error).ffLabel(size: 10, color: T.lichen)
            }
            HStack(spacing: T.cells(1)) {
                Spacer()
                Button("Cancel") { model.presetSheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.ff)
                Button(renaming == nil ? "Save" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ffProminent)
                    .disabled(!canSave)
            }
        }
        .padding(T.cells(3))
        .frame(width: T.cells(44))
        .fieldFramesWindow()
        .onAppear {
            if let id = renaming, let p = model.presetStore.preset(id: id) { nickname = p.nickname }
            focused = true
        }
    }

    @ViewBuilder private var nicknameField: some View {
        if snapshot {
            Text(nickname)
                .font(T.mono(11))
                .foregroundStyle(T.paper)
                .padding(.horizontal, T.cells(1))
                .frame(maxWidth: .infinity, minHeight: T.rows(2), alignment: .leading)
                .overlay(Rectangle().strokeBorder(T.lichen, lineWidth: 1))
        } else {
                TextField("", text: $nickname, prompt: Text("E.G. LAST SUMMER").font(T.mono(10)).foregroundColor(T.paperDim))
                    .textFieldStyle(.plain)
                    .font(T.mono(11))
                    .foregroundStyle(T.paper)
                    .padding(.horizontal, T.cells(1))
                    .frame(height: T.rows(2))
                    .overlay(Rectangle().strokeBorder(focused ? T.lichen : T.hair, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel("Preset nickname")
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let id = renaming {
                try model.renamePreset(id, nickname: trimmed)
            } else {
                try model.saveCurrentAsPreset(nickname: trimmed)
            }
            model.presetSheet = nil
        } catch {
            self.error = "COULD NOT SAVE THE PRESET"
        }
    }
}
