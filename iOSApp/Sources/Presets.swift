import MiraCore
import MiraUI
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private typealias T = FieldFramesTheme

/// A duplicate found while importing: the dialog asks what to do with it.
struct PresetConflict: Identifiable, Equatable {
    let id = UUID()
    let incoming: Preset
    let existing: Preset
    let keepBothNickname: String
    let fileCount: Int
    let remaining: Int
}

enum PresetSheet: Identifiable, Equatable {
    case save
    case rename(UUID)
    var id: String {
        switch self {
        case .save: "save"
        case .rename(let id): "rename-\(id)"
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The iPhone's side of presets: the SAME `PresetStore.shared` / `PresetFile` / `PresetImport` the Mac
/// uses, plus the sheet, share and import state the views need. One per app (open-in-place URLs reach it
/// from `onOpenURL` before any editor exists).
@MainActor @Observable
final class PresetHub {
    static let shared = PresetHub()

    let store = PresetStore.shared
    private(set) var presets: [Preset] = []
    var sheet: PresetSheet?
    var pendingDelete: Preset?
    var shareItem: ShareItem?
    var importerShown = false
    private(set) var notice: String?
    private(set) var conflict: PresetConflict?
    private(set) var isImporting = false

    @ObservationIgnored private var continuation: CheckedContinuation<PresetImportChoice, Never>?
    @ObservationIgnored private var applyToAll: PresetImportChoice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var shareDirectory: URL?

    init() { refresh() }

    /// The version written into exported files.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    func refresh() { presets = store.all }

    func showNotice(_ text: String, seconds: Double = 6) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Editing

    func save(nickname: String, recipe: Recipe, filmName: String) throws {
        _ = try store.add(nickname: nickname, recipe: recipe, filmName: filmName)
        refresh()
    }

    func rename(_ id: UUID, nickname: String) throws {
        _ = try store.rename(id: id, nickname: nickname)
        refresh()
    }

    func duplicate(_ id: UUID) {
        do { _ = try store.duplicate(id: id) } catch { showNotice("Could not duplicate the preset.") }
        refresh()
    }

    func delete(_ id: UUID) {
        do { try store.delete(id: id) } catch { showNotice("Could not delete the preset.") }
        refresh()
    }

    // MARK: Share

    /// Writes "<Film> - <nickname>.mirapreset" to a temp folder and opens the share sheet on it.
    func share(_ preset: Preset) {
        do {
            if let old = shareDirectory { try? FileManager.default.removeItem(at: old) }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiraShare-\(UUID().uuidString)", isDirectory: true)
            shareDirectory = dir
            let url = try PresetFile.write(preset, into: dir, appVersion: Self.appVersion, uniquely: false)
            shareItem = ShareItem(url: url)
        } catch {
            showNotice("Could not prepare the preset for sharing.")
        }
    }

    // MARK: Import

    /// Imports the preset files among `urls` (others are ignored); the notice reports the result.
    func startImport(_ urls: [URL]) {
        let files = urls.filter(PresetFile.isPresetFile)
        guard !files.isEmpty, !isImporting else { return }
        Task { _ = await importPresets(from: files) }
    }

    @discardableResult
    func importPresets(from urls: [URL]) async -> PresetImportOutcome {
        isImporting = true
        applyToAll = nil
        defer { isImporting = false; applyToAll = nil }
        let count = urls.count
        let outcome = await store.importPresets(from: urls) { [self] incoming, existing, remaining in
            if let choice = applyToAll { return choice }
            let keep = PresetFile.uniqueNickname(incoming.nickname, filmName: incoming.filmName, among: store.all)
            conflict = PresetConflict(incoming: incoming, existing: existing, keepBothNickname: keep,
                                      fileCount: count, remaining: remaining)
            return await withCheckedContinuation { continuation = $0 }
        }
        conflict = nil
        refresh()
        showNotice(outcome.summary, seconds: outcome.failures.isEmpty ? 6 : 14)
        return outcome
    }

    func resolveConflict(_ choice: PresetImportChoice, toAll: Bool = false) {
        if toAll { applyToAll = choice }
        conflict = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: choice)
    }
}

// MARK: Name styling

enum PresetText {
    /// "Film - Nickname": film name inherited, dim hyphen, nickname in Cormorant italic lichen.
    static func name(film: String, nickname: String, size: CGFloat = 16) -> Text {
        Text("\(Text(film))\(nicknamePart(nickname, size: size, leading: " - "))")
    }

    static func nicknamePart(_ nickname: String, size: CGFloat = 16, leading: String = "- ") -> Text {
        let dash = Text(leading).foregroundStyle(T.paperDim)
        let name = Text(nickname).font(T.displayItalic(size, weight: .medium)).foregroundStyle(T.lichen)
        return Text("\(dash)\(name)")
    }
}

// MARK: Strip group

/// A labelled group in the FILMS strip: mono label + count, hairline, then the cards.
struct StripGroup<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: T.cells(1)) {
                Text(title).ffLabel(size: 10, color: T.paperMid)
                Text(String(format: "%02d", count)).ffLabel(size: 9, color: T.paperDim)
            }
            .padding(.leading, 4)
            .frame(height: T.rows(1.5), alignment: .leading)
            FFHairline()
            HStack(alignment: .top, spacing: T.cells(1)) { content }
                .padding(.top, T.rows(0.5))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct PresetGroup: View {
    @Bindable var model: EditorViewModel
    let hub: PresetHub

    var body: some View {
        StripGroup(title: "PRESETS", count: hub.presets.count) {
            if hub.presets.isEmpty {
                PresetEmptySlot(hub: hub)
            } else {
                ForEach(hub.presets) { preset in
                    PresetCardView(model: model, hub: hub, preset: preset)
                }
            }
        }
    }
}

struct PresetCardView: View {
    @Bindable var model: EditorViewModel
    let hub: PresetHub
    let preset: Preset

    var body: some View {
        let missing = model.isFilmMissing(preset)
        let film = PhotoEngine.filmList.first { $0.id == preset.filmID }
        FilmCard(
            title: Text(preset.filmName),
            secondLine: PresetText.nicknamePart(preset.nickname),
            accessibilityTitle: preset.displayName,
            caption: missing ? "Film missing" : (film.map { $0.iso > 0 ? "\($0.brand) \u{00B7} \($0.iso)" : $0.brand } ?? "No film"),
            captionTint: missing ? T.paper : nil,
            image: model.thumbnails[preset.filmID ?? "__original"],
            isSelected: model.isApplied(preset)
        ) { model.apply(preset) }
        .task(id: model.thumbEpoch) { await model.requestThumbnail(preset.filmID) }
        .contextMenu {
            Button { hub.share(preset) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { hub.sheet = .rename(preset.id) } label: { Label("Rename", systemImage: "pencil") }
            Button { hub.duplicate(preset.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { hub.pendingDelete = preset } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// Where the preset cards go before there are any: the size of a film card, dashed hairline.
private struct PresetEmptySlot: View {
    let hub: PresetHub

    var body: some View {
        Button { hub.sheet = .save } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: T.rows(0.5)) {
                    Text("+").font(T.display(26, weight: .medium)).foregroundStyle(T.paperMid)
                    Text("SAVE A PRESET").ffLabel(size: 10, color: T.paperMid)
                }
                .frame(width: FilmCard.width, height: FilmCard.thumbnailHeight)
                .overlay(Rectangle().strokeBorder(T.hair, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text("FILM AND DEVELOP").ffLabel(size: 9, color: T.paperDim).padding(.top, 6)
            }
            .frame(width: FilmCard.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save a preset")
    }
}

// MARK: Save / rename sheet

/// SAVE PRESET / RENAME: film name fixed, nickname a mono field, final name previewed.
/// Laid out like the Mac sheet.
struct SavePresetSheet: View {
    let model: EditorViewModel
    let hub: PresetHub
    let mode: PresetSheet
    @State private var nickname: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(model: EditorViewModel, hub: PresetHub, mode: PresetSheet, initialNickname: String = "") {
        self.model = model
        self.hub = hub
        self.mode = mode
        _nickname = State(initialValue: initialNickname)
    }

    private var renaming: UUID? {
        if case .rename(let id) = mode { return id }
        return nil
    }

    private var filmName: String {
        if let id = renaming, let p = hub.store.preset(id: id) { return p.filmName }
        return model.currentFilmName
    }

    static let keepsNote = "Presets keep the film and develop settings; dodge & burn strokes stay with the photo."

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.rows(1)) {
                Text(renaming == nil ? "Save Preset" : "Rename Preset")
                    .font(T.display(30, weight: .medium))
                FFHairline()
                FFSectionLabel("Film")
                Text(filmName)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paperSoft)
                FFSectionLabel("Nickname")
                TextField("", text: $nickname, prompt: Text("E.G. LAST SUMMER").font(T.mono(10)).foregroundColor(T.paperDim))
                    .textFieldStyle(.plain)
                    .font(T.mono(13))
                    .foregroundStyle(T.paper)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, T.cells(1))
                    .frame(height: max(T.rows(2), 44))
                    .overlay(Rectangle().strokeBorder(focused ? T.lichen : T.hair, lineWidth: 1))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityLabel("Preset nickname")
                FFSectionLabel("Preset name")
                Group {
                    if canSave {
                        PresetText.name(film: filmName, nickname: trimmed, size: 21)
                            .font(T.display(21, weight: .medium))
                            .foregroundStyle(T.paper)
                    } else {
                        Text("Type a nickname to name this preset").ffLabel(color: T.paperDim)
                    }
                }
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: T.rows(2), alignment: .leading)
                Text(Self.keepsNote)
                    .ffLabel(size: 9, color: T.paperDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).ffLabel(size: 10, color: T.lichen) }
                HStack(spacing: T.cells(1)) {
                    Spacer()
                    Button("Cancel") { hub.sheet = nil }.buttonStyle(.ff)
                    Button(renaming == nil ? "Save" : "Rename", action: save)
                        .buttonStyle(.ffProminent)
                        .disabled(!canSave)
                }
            }
            .padding(T.cells(3))
        }
        .background(FFGroundBackground(grain: 0.07).ignoresSafeArea())
        .foregroundStyle(T.paper)
        .tint(T.lichen)
        .presentationDetents([.medium, .large])
        .onAppear {
            if let id = renaming, let p = hub.store.preset(id: id) { nickname = p.nickname }
            if ProcessInfo.processInfo.environment["MIRA_SNAPSHOT"] != "1" { focused = true }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let id = renaming {
                try hub.rename(id, nickname: trimmed)
            } else {
                try hub.save(nickname: trimmed, recipe: model.recipe, filmName: model.currentFilmName)
            }
            hub.sheet = nil
        } catch {
            self.error = "COULD NOT SAVE THE PRESET"
        }
    }
}

// MARK: Duplicate dialog

/// "Preset Already Exists": Replace / Keep Both / Skip, with APPLY TO ALL for multi-file imports.
struct PresetConflictSheet: View {
    let hub: PresetHub
    let conflict: PresetConflict
    @State private var toAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.rows(1)) {
                Text("Preset Already Exists").font(T.display(30, weight: .medium))
                FFHairline()
                FFSectionLabel("Already saved")
                PresetText.name(film: conflict.existing.filmName, nickname: conflict.existing.nickname, size: 21)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paper)
                    .lineLimit(2)
                    .accessibilityLabel(conflict.existing.displayName)
                FFSectionLabel("Importing")
                PresetText.name(film: conflict.incoming.filmName, nickname: conflict.incoming.nickname, size: 21)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paperSoft)
                    .lineLimit(2)
                    .accessibilityLabel(conflict.incoming.displayName)
                Text("Replace swaps the saved look for the imported one. Keep Both saves the import as \u{201C}\(conflict.keepBothNickname)\u{201D}. Skip leaves it out.")
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(T.paperMid)
                    .fixedSize(horizontal: false, vertical: true)
                if conflict.fileCount > 1 {
                    FFToggle("Apply to all", isOn: $toAll)
                }
                HStack(spacing: T.cells(1)) {
                    Spacer()
                    Button("Skip") { hub.resolveConflict(.skip, toAll: toAll) }.buttonStyle(.ff)
                    Button("Replace") { hub.resolveConflict(.replace, toAll: toAll) }.buttonStyle(.ff)
                    Button("Keep Both") { hub.resolveConflict(.keepBoth, toAll: toAll) }.buttonStyle(.ffProminent)
                }
            }
            .padding(T.cells(3))
        }
        .background(FFGroundBackground(grain: 0.07).ignoresSafeArea())
        .foregroundStyle(T.paper)
        .tint(T.lichen)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

// MARK: Share sheet

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: Presentation (sheets, dialogs, importer, notice) for the whole app

struct PresetPresentations: ViewModifier {
    let hub: PresetHub
    let model: EditorViewModel

    func body(content: Content) -> some View {
        @Bindable var hub = hub
        content
            .sheet(item: $hub.sheet) { mode in
                SavePresetSheet(model: model, hub: hub, mode: mode,
                                initialNickname: ProcessInfo.processInfo.environment["MIRA_SNAPSHOT"] == "1"
                                    && mode == .save ? "Golden Hour" : "")
            }
            .sheet(item: Binding(
                get: { hub.conflict },
                set: { if $0 == nil, hub.conflict != nil { hub.resolveConflict(.skip) } }
            )) { conflict in
                PresetConflictSheet(hub: hub, conflict: conflict)
            }
            .sheet(item: $hub.shareItem) { item in
                ActivityView(url: item.url).presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $hub.importerShown, allowedContentTypes: [.miraPreset],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { hub.startImport(urls) }
            }
            .confirmationDialog(
                hub.pendingDelete.map { "Delete \u{201C}\($0.displayName)\u{201D}?" } ?? "Delete preset?",
                isPresented: Binding(get: { hub.pendingDelete != nil }, set: { if !$0 { hub.pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let p = hub.pendingDelete { hub.delete(p.id) }
                    hub.pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { hub.pendingDelete = nil }
            } message: {
                Text("The saved look is removed. Photos already edited with it are not changed.")
            }
            .overlay(alignment: .top) {
                if let notice = hub.notice {
                    Text(notice)
                        .ffLabel(size: 10, color: T.paper)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, T.cells(2)).padding(.vertical, 10)
                        .background(T.inkSoft.opacity(0.96))
                        .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
                        .padding(.top, 52).padding(.horizontal, T.cells(2))
                        .transition(.opacity)
                        .onTapGesture { }
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.easeOut(duration: 0.2), value: hub.notice)
    }
}

extension View {
    func presetPresentations(hub: PresetHub, model: EditorViewModel) -> some View {
        modifier(PresetPresentations(hub: hub, model: model))
    }
}

// MARK: Editor glue

extension EditorViewModel {
    var currentFilmName: String {
        PhotoEngine.filmList.first { $0.id == recipe.filmID }?.displayName ?? Preset.originalName
    }

    func isFilmMissing(_ preset: Preset) -> Bool {
        guard let id = preset.filmID else { return false }
        return !PhotoEngine.filmList.contains { $0.id == id }
    }

    /// What applying `preset` gives right now: its look, the photo's crop and brushwork (a missing film becomes none).
    func appliedRecipe(for preset: Preset) -> Recipe {
        var r = preset.recipe(keeping: recipe.crop, dodgeBurn: recipe.dodgeBurn, raw: recipe.raw)
        if isFilmMissing(preset) { r.filmID = nil }
        return r
    }

    func isApplied(_ preset: Preset) -> Bool { recipe == appliedRecipe(for: preset) }

    /// Live: mutating `recipe` re-renders the Metal preview immediately.
    func apply(_ preset: Preset) { recipe = appliedRecipe(for: preset) }
}
