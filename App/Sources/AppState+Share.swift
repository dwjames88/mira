import AppKit
import Photos
import MiraCore
import MiraUI
import UniformTypeIdentifiers

/// The format and quality File > Export last used. Share renders with the same pair, so a shared
/// picture matches an exported one. Defaults: JPEG at 0.92 (the Export sheet's defaults).
enum ExportSettings {
    static let formatKey = "mira.export.format"
    static let qualityKey = "mira.export.quality"
    static let defaultQuality = 0.92

    static func current(_ defaults: UserDefaults = .standard) -> (format: ExportFormat, quality: Double) {
        let format = defaults.string(forKey: formatKey).flatMap(ExportFormat.init(rawValue:)) ?? .jpeg
        let stored = defaults.object(forKey: qualityKey) as? Double
        return (format, min(max(stored ?? defaultQuality, 0.5), 1))
    }

    static func remember(format: ExportFormat, quality: Double, in defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: formatKey)
        defaults.set(quality, forKey: qualityKey)
    }
}

/// Keeps the share sheet alive while it is open.
@MainActor
private enum ShareSheet {
    static var picker: NSSharingServicePicker?
}

extension AppState {
    /// File > Share... and the strip button: a photo is open and nothing else is rendering.
    var canShare: Bool {
        EditorHostBar.Share.isAvailable(hasPhoto: hasPhoto, isBusy: isBusy || isExporting,
                                        isCropping: isCropping, isSharing: isSharing)
    }

    /// The strip's Share button (app only; the Photos extension passes none).
    var shareControl: EditorHostBar.Share {
        .init(isEnabled: canShare, isBusy: isSharing) { [self] frame in share(anchorFrame: frame) }
    }

    /// Renders the current look at full size to a temporary file and opens the system share sheet
    /// on it. `anchorFrame` is the button in window coordinates; the menu passes nil and the sheet hangs from the canvas.
    func share(anchorFrame: CGRect?) {
        guard canShare, let editor, editor.source != nil else { return }
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
        let recipe = editor.recipe
        let renderer = editor.renderer
        let settings = ExportSettings.current()
        let type = settings.format.type
        isSharing = true
        // Quick renders show nothing but the button's spinner; a slow one gets the overlay.
        let slow = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { self?.shareBusyText = "Preparing to share" }
        }
        Task {
            defer {
                slow.cancel()
                shareBusyText = nil
                isSharing = false
            }
            guard let source = await editor.fullSource() else {
                errorMessage = "Share failed: the full-size picture could not be read."
                return
            }
            let box = Unchecked(value: source)
            let colorSpace: CGColorSpace? = metadataURL.map { ImageSource.outputColorSpace(url: $0, image: source) }
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let staging = ShareRender.Staging.shared
                    return try ShareRender.render(
                        recipe, source: box.value, metadataFrom: metadataURL, baseName: baseName,
                        type: type, quality: settings.quality, colorSpace: colorSpace,
                        renderer: renderer, directory: try staging.nextDirectory())
                }
            }.value
            switch result {
            case .failure(let error):
                errorMessage = "Share failed: \(error)"
            case .success(let url):
                // The photo was closed while rendering: nothing to share any more.
                guard self.editor === editor else { return }
                present(url, from: anchorFrame)
            }
        }
    }

    private func present(_ url: URL, from frame: CGRect?) {
        guard let content = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        ShareSheet.picker = picker
        var rect = NSRect(x: content.bounds.midX, y: content.bounds.midY, width: 1, height: 1)
        if let frame, !frame.isEmpty {
            rect = frame
            if !content.isFlipped { rect.origin.y = content.bounds.height - frame.maxY }
        }
        picker.show(relativeTo: rect, of: content, preferredEdge: .minY)
    }

    /// Removes share files left by earlier launches.
    nonisolated static func cleanShareStaging() {
        ShareRender.Staging.shared.removeStale()
    }
}
