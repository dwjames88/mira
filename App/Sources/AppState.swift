import AppKit
import CoreImage
import EmulsionCore
import EmulsionUI
import Observation
import Photos
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF"

    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }
}

/// App-level state: the window mode, the open photo (Photos asset or file), its editor, and export.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Mode { case library, editor }

    /// A file opened from disk: edits live in a sidecar, never in the file.
    struct FileTarget {
        let url: URL
        /// The recipe last written to (or read from) a sidecar; nil when none exists.
        var persisted: Recipe?
        var location: SidecarLocation?
    }

    enum Target {
        case asset(AssetEditSession)
        case file(FileTarget)
    }

    let library: FilmLibrary?
    let store = LibraryStore()
    var mode: Mode = .library
    private(set) var editor: EditorModel?
    private(set) var target: Target?
    var errorMessage: String?
    var showExportSheet = false
    private(set) var isExporting = false

    /// Busy line ("OPENING", "SAVING") shown over the editor; nil when idle.
    private(set) var busyText: String?
    private(set) var busyProgress: Double?
    /// One-line mono notes under the editor.
    private(set) var statusLine: String?
    private(set) var resultLine: String?
    private(set) var editorNote: String?
    var libraryNote: String?

    var showLeaveDialog = false
    var showRevertConfirm = false

    private var loadedRecipe = Recipe.neutral
    private var canSaveToPhotos = false
    @ObservationIgnored private var pendingLeave: (@MainActor () -> Void)?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var trackGeneration = 0
    @ObservationIgnored private var sidecarTask: Task<Void, Never>?
    @ObservationIgnored private let sidecars = SidecarStore(fallbackDirectory: SidecarStore.defaultFallbackDirectory())
    @ObservationIgnored private var selfTestStarted = false

    init() {
        library = FilmLibrary.bundled()
        if let library {
            Task(priority: .utility) { await library.prewarm() }
        }
    }

    var hasPhoto: Bool { editor != nil }
    var isAssetTarget: Bool { if case .asset = target { true } else { false } }
    var isFileTarget: Bool { if case .file = target { true } else { false } }
    var isBusy: Bool { busyText != nil }

    /// Unsaved work in a Photos edit (files autosave to their sidecar).
    var isDirty: Bool {
        guard isAssetTarget, let editor else { return false }
        return EditDirtyCheck.isDirty(current: editor.recipe, loaded: loadedRecipe)
    }

    var canSave: Bool { isAssetTarget && canSaveToPhotos && isDirty && !isBusy }
    var canRevert: Bool {
        switch target {
        case .asset(let session): session.asset.hasAdjustments && !isBusy
        case .file(let file): (file.persisted != nil || editor?.recipe != .neutral) && !isBusy
        case nil: false
        }
    }

    // MARK: Leaving

    /// Runs `action` now, or after the user decides what to do with unsaved Photos edits.
    func guardedLeave(_ action: @escaping @MainActor () -> Void) {
        if isDirty {
            pendingLeave = action
            showLeaveDialog = true
        } else {
            action()
        }
    }

    func confirmLeaveSaving() {
        let action = pendingLeave
        pendingLeave = nil
        Task {
            if await saveToPhotos() { action?() }
        }
    }

    func confirmLeaveDiscarding() {
        let action = pendingLeave
        pendingLeave = nil
        action?()
    }

    func cancelLeave() {
        pendingLeave = nil
    }

    func showLibrary() {
        guardedLeave { [self] in closeEditor() }
    }

    private func closeEditor() {
        flushSidecar()
        loadGeneration += 1
        trackGeneration += 1
        editor?.cancelWork()
        editor = nil
        target = nil
        editorNote = nil
        statusLine = nil
        resultLine = nil
        busyText = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        mode = .library
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open a Photo"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Files passed at launch or by Finder.
    func handleOpen(_ urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        if case .file(let file) = target, file.url == url, mode == .editor { return }
        open(url: url)
        NSApp.activate()
    }

    func open(url: URL) {
        guardedLeave { [self] in openFile(url) }
    }

    private func openFile(_ url: URL) {
        guard let library else {
            errorMessage = "Emulsion could not load its film library."
            return
        }
        flushSidecar()
        scopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        let model = EditorModel(library: library)
        guard model.loadSource(url: url) else {
            errorMessage = "\(url.lastPathComponent) could not be opened as an image."
            return
        }
        loadGeneration += 1
        let restored = sidecars.load(for: url)
        let location = sidecars.location(for: url)
        model.recipe = restored ?? .neutral
        editor = model
        target = .file(FileTarget(url: url, persisted: restored, location: location))
        loadedRecipe = model.recipe
        canSaveToPhotos = false
        editorNote = nil
        resultLine = nil
        statusLine = SidecarStatus.line(location: location, imageURL: url)
        mode = .editor
        track()
    }

    func openAsset(_ asset: PHAsset) {
        guardedLeave { [self] in
            Task { await loadAsset(AssetEditSession(asset: asset)) }
        }
    }

    private func loadAsset(_ session: AssetEditSession) async {
        guard let library else {
            errorMessage = "Emulsion could not load its film library."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        busyText = "Opening"
        busyProgress = nil
        defer { if generation == loadGeneration { busyText = nil } }
        do {
            let loaded = try await session.load(progress: { [weak self] p in
                if self?.loadGeneration == generation { self?.busyProgress = p }
            })
            guard generation == loadGeneration else { return }
            flushSidecar()
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            let model = EditorModel(library: library)
            model.setSource(loaded.source)
            model.recipe = loaded.recipe
            editor = model
            target = .asset(session)
            loadedRecipe = loaded.recipe
            canSaveToPhotos = loaded.isFullSize
            resultLine = nil
            statusLine = "PHOTOS \u{00B7} ORIGINAL IS KEPT, REVERT IN PHOTOS OR HERE"
            if let foreign = loaded.foreignFormat {
                editorNote = "Saving will replace edits made in \(Self.appHint(for: foreign))."
            } else if !loaded.isFullSize {
                editorNote = "Only a preview of this picture is available, so it cannot be saved."
            } else {
                editorNote = nil
            }
            mode = .editor
            track()
        } catch {
            if generation == loadGeneration { errorMessage = "Could not open the picture: \(error)" }
        }
    }

    private static func appHint(for formatIdentifier: String) -> String {
        if formatIdentifier.hasPrefix("com.apple.photos") || formatIdentifier.hasPrefix("com.apple.Photos") { return "Photos" }
        if formatIdentifier.localizedCaseInsensitiveContains("photomator") || formatIdentifier.localizedCaseInsensitiveContains("pixelmator") { return "Photomator" }
        return "another app (\(formatIdentifier))"
    }

    // MARK: Recipe tracking and sidecar autosave

    private func track() {
        guard let model = editor else { return }
        trackGeneration += 1
        let generation = trackGeneration
        observe(model, generation)
    }

    private func observe(_ model: EditorModel, _ generation: Int) {
        withObservationTracking {
            _ = model.recipe
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackGeneration == generation else { return }
                self.recipeChanged()
                self.observe(model, generation)
            }
        }
    }

    private func recipeChanged() {
        resultLine = nil
        guard isFileTarget else { return }
        sidecarTask?.cancel()
        sidecarTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.writeSidecar()
        }
    }

    private func flushSidecar() {
        sidecarTask?.cancel()
        sidecarTask = nil
        writeSidecar()
    }

    private func writeSidecar() {
        guard case .file(var file) = target, let editor else { return }
        let recipe = editor.recipe
        guard recipe != (file.persisted ?? .neutral) else { return }
        do {
            let location = try sidecars.save(recipe, for: file.url)
            file.persisted = recipe
            file.location = location
            target = .file(file)
            statusLine = SidecarStatus.line(location: location, imageURL: file.url)
        } catch {
            statusLine = "SIDECAR \u{00B7} COULD NOT BE WRITTEN"
        }
    }

    // MARK: Save and revert

    @discardableResult
    func saveToPhotos() async -> Bool {
        guard case .asset(let session) = target, let editor, let source = editor.source else { return false }
        let recipe = editor.recipe
        busyText = "Saving"
        busyProgress = nil
        resultLine = nil
        defer { busyText = nil }
        do {
            try await session.save(recipe: recipe, source: source, renderer: editor.renderer)
            loadedRecipe = recipe
            resultLine = "SAVED TO PHOTOS"
            return true
        } catch {
            resultLine = nil
            errorMessage = "Could not save to Photos: \(error)"
            return false
        }
    }

    func revertToOriginal() async {
        switch target {
        case .asset(let session):
            busyText = "Reverting"
            do {
                try await session.revert()
                busyText = nil
                await loadAsset(session)
                resultLine = "REVERTED TO ORIGINAL"
            } catch {
                busyText = nil
                errorMessage = "Could not revert: \(error)"
            }
        case .file(var file):
            sidecarTask?.cancel()
            do {
                try sidecars.remove(for: file.url)
            } catch {
                errorMessage = "The sidecar could not be removed: \(error)"
            }
            file.persisted = nil
            file.location = nil
            target = .file(file)
            editor?.recipe = .neutral
            statusLine = SidecarStatus.line(location: nil, imageURL: file.url)
            resultLine = "REVERTED TO ORIGINAL"
        case nil:
            break
        }
    }

    // MARK: Export

    func export(format: ExportFormat, quality: Double) {
        guard let editor, let source = editor.source else { return }
        let metadataURL: URL?
        let baseName: String
        switch target {
        case .file(let file):
            metadataURL = file.url
            baseName = file.url.deletingPathExtension().lastPathComponent
        case .asset(let session):
            metadataURL = session.fullSizeURL
            baseName = PHAssetResource.assetResources(for: session.asset).first
                .map { URL(fileURLWithPath: $0.originalFilename).deletingPathExtension().lastPathComponent } ?? "Photo"
        case nil:
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = baseName + " Emulsion." + format.fileExtension
        panel.title = "Export Photo"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let recipe = editor.recipe
        let renderer = editor.renderer
        let type = format.type
        let box = Unchecked(value: source)
        let colorSpace: CGColorSpace? = metadataURL.map { ImageSource.outputColorSpace(url: $0, image: source) }
        isExporting = true
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try renderer.export(recipe, source: box.value, metadataFrom: metadataURL, outputURL: outputURL,
                                        type: type, quality: quality, colorSpace: colorSpace)
                }
            }.value
            isExporting = false
            if case .failure(let error) = result {
                errorMessage = "Export failed: \(error)"
            }
        }
    }

    // MARK: Self test

    func runSelfTestsIfRequested() {
        guard !selfTestStarted else { return }
        let args = CommandLine.arguments
        guard args.contains("--selftest-photos") || args.contains("--selftest-sidecar") else { return }
        selfTestStarted = true
        guard let library else { return }
        if args.contains("--selftest-sidecar") { SelfTest.runSidecar() }
        if args.contains("--selftest-photos") {
            Task { await SelfTest.runPhotos(library: library) }
        }
    }
}
