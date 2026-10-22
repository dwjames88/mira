import AppKit
import MiraCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A duplicate found while importing: the dialog asks what to do with it.
public struct PresetConflict: Identifiable, Equatable {
    public let id = UUID()
    public let incoming: Preset
    public let existing: Preset
    /// The nickname "Keep Both" would give the incoming preset.
    public let keepBothNickname: String
    /// Files in this import, and how many later ones may also clash.
    public let fileCount: Int
    public let remaining: Int
}

/// Sharing presets as `.mirapreset` files: Share (system share sheet), Export, Export All and Import,
/// plus the duplicate dialog's state. One per app; the Photos extension has one with sharing off
/// (it is sandboxed without file-panel access), so it keeps the shared store but shows no share or import UI.
@MainActor
@Observable
public final class PresetTransfer {
    public let store: PresetStore
    /// True where open / save panels and the share sheet work (the app).
    public var sharingEnabled: Bool
    /// What the last share, export or import did; clears itself.
    public internal(set) var notice: String?
    /// The duplicate the dialog is asking about, nil when there is none.
    public internal(set) var conflict: PresetConflict?
    public internal(set) var isImporting = false

    /// Called after the store changed (an import), so open editors reload their preset list.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var continuation: CheckedContinuation<PresetImportChoice, Never>?
    @ObservationIgnored private var applyToAll: PresetImportChoice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var anchors: [UUID: WeakView] = [:]
    @ObservationIgnored private var picker: NSSharingServicePicker?
    @ObservationIgnored private var shareDirectory: URL?

    private struct WeakView { weak var view: NSView? }

    public init(store: PresetStore, sharingEnabled: Bool = false) {
        self.store = store
        self.sharingEnabled = sharingEnabled
    }

    /// The version written into exported files.
    public static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.3.1"
    }

    // MARK: Notice

    func showNotice(_ text: String, seconds: Double = 6) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Import

    /// Menu: Preset > Import Presets... Choose one or more `.mirapreset` files.
    public func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.miraPreset]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        startImport(panel.urls)
    }

    /// Imports the preset files among `urls` (other files are ignored). Returns at once; the notice
    /// reports the result.
    public func startImport(_ urls: [URL]) {
        let files = urls.filter(PresetFile.isPresetFile)
        guard !files.isEmpty, !isImporting else { return }
        Task { _ = await importPresets(from: files) }
    }

    /// The import itself, for tests and for `startImport`.
    @discardableResult
    public func importPresets(from urls: [URL]) async -> PresetImportOutcome {
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
        onChange?()
        showNotice(outcome.summary, seconds: outcome.failures.isEmpty ? 6 : 14)
        return outcome
    }

    /// The duplicate dialog's answer. `toAll` reuses it for the rest of this import.
    public func resolveConflict(_ choice: PresetImportChoice, toAll: Bool = false) {
        if toAll { applyToAll = choice }
        conflict = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: choice)
    }

    // MARK: Export

    /// The share sheet needs a view to hang from: each preset card registers its own.
    func register(anchor: NSView, for id: UUID) {
        anchors[id] = WeakView(view: anchor)
    }

    /// Context menu: Share... AirDrop, Messages, Mail and the rest, with the `.mirapreset` file.
    public func share(_ preset: Preset) {
        guard sharingEnabled else { return }
        do {
            let url = try temporaryFile(for: preset)
            let anchor = anchors[preset.id]?.view ?? NSApp.keyWindow?.contentView
            guard let anchor else { return }
            let picker = NSSharingServicePicker(items: [url])
            self.picker = picker
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            showNotice("Could not prepare the preset for sharing.")
        }
    }

    private func temporaryFile(for preset: Preset) throws -> URL {
        if let old = shareDirectory { try? FileManager.default.removeItem(at: old) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MiraShare-\(UUID().uuidString)", isDirectory: true)
        shareDirectory = dir
        return try PresetFile.write(preset, into: dir, appVersion: Self.appVersion, uniquely: false)
    }

    /// Context menu: Export... A save panel with "<Film> - <nickname>.mirapreset".
    public func export(_ preset: Preset) {
        guard sharingEnabled else { return }
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.miraPreset]
        panel.nameFieldStringValue = PresetFile.fileName(for: preset)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PresetFile.encode(preset, appVersion: Self.appVersion)
            try data.write(to: url, options: .atomic)
            showNotice("Exported \(url.lastPathComponent).")
        } catch {
            showNotice("Could not export \(url.lastPathComponent).")
        }
    }

    /// Menu: Preset > Export All Presets... Pick a folder; one file per preset.
    public func exportAll() {
        guard sharingEnabled else { return }
        let presets = store.all
        guard !presets.isEmpty else {
            showNotice("There are no presets to export.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Export All Presets"
        panel.message = "Choose a folder for \(presets.count) \(presets.count == 1 ? "preset" : "presets")."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        showNotice(exportAll(to: folder))
    }

    /// Writes every preset into `folder`; returns the notice text.
    @discardableResult
    func exportAll(to folder: URL) -> String {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var written = 0
        for preset in store.all {
            if (try? PresetFile.write(preset, into: folder, appVersion: Self.appVersion)) != nil { written += 1 }
        }
        let total = store.all.count
        if written == total { return "Exported \(written) \(written == 1 ? "preset" : "presets") to \(folder.lastPathComponent)." }
        return "Exported \(written) of \(total) presets to \(folder.lastPathComponent)."
    }
}

/// Registers the card's NSView as the anchor of its share sheet.
struct ShareAnchor: NSViewRepresentable {
    let transfer: PresetTransfer
    let id: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        transfer.register(anchor: view, for: id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        transfer.register(anchor: view, for: id)
    }
}

// MARK: Duplicate dialog

private typealias T = FieldFramesTheme

/// "Preset already exists": Replace / Keep Both / Skip, with APPLY TO ALL for a multi-file import.
/// Laid out like the Save Preset sheet.
public struct PresetConflictSheet: View {
    let transfer: PresetTransfer
    let conflict: PresetConflict
    @State private var toAll = false

    public init(transfer: PresetTransfer, conflict: PresetConflict, applyToAllOn: Bool = false) {
        self.transfer = transfer
        self.conflict = conflict
        _toAll = State(initialValue: applyToAllOn)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: T.rows(1)) {
            Text("Preset Already Exists")
                .font(T.display(30, weight: .medium))
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
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(T.paperMid)
                .fixedSize(horizontal: false, vertical: true)
            if conflict.fileCount > 1 {
                FFToggle("Apply to all", isOn: $toAll)
                    .accessibilityHint("Use this answer for every other duplicate in this import")
            }
            HStack(spacing: T.cells(1)) {
                Spacer()
                Button("Skip") { transfer.resolveConflict(.skip, toAll: toAll) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.ff)
                Button("Replace") { transfer.resolveConflict(.replace, toAll: toAll) }
                    .buttonStyle(.ff)
                Button("Keep Both") { transfer.resolveConflict(.keepBoth, toAll: toAll) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ffProminent)
            }
        }
        .padding(T.cells(3))
        .frame(width: T.cells(44))
        .fieldFramesWindow()
    }
}

extension View {
    /// Presents the duplicate dialog while `transfer` has a conflict. Closing it any other way counts as Skip.
    public func presetImportSheet(_ transfer: PresetTransfer, active: Bool = true) -> some View {
        sheet(item: Binding(
            get: { active ? transfer.conflict : nil },
            set: { if $0 == nil, transfer.conflict != nil, active { transfer.resolveConflict(.skip) } }
        )) { conflict in
            PresetConflictSheet(transfer: transfer, conflict: conflict)
        }
    }
}
