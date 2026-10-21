import AppKit
import EmulsionCore
import EmulsionUI
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Carries a non-Sendable value (the Photos completion handler) back to the main actor.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// The Photos editing extension: hosts the shared editor and writes the recipe as adjustment data.
final class PhotoEditingViewController: NSViewController, PHContentEditingController {
    private var model: EditorModel?
    private var input: PHContentEditingInput?
    private var startRecipe = Recipe.neutral
    private var exportTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        container.autoresizingMask = [.width, .height]
        view = container
        preferredContentSize = NSSize(width: 1100, height: 750)

        guard let library = FilmLibrary.bundled() else {
            let label = NSTextField(labelWithString: "Emulsion could not load its film library.")
            label.frame = container.bounds
            label.alignment = .center
            label.autoresizingMask = [.width, .height]
            container.addSubview(label)
            return
        }
        let model = EditorModel(library: library)
        self.model = model
        let host = NSHostingView(rootView: EditorView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }

    // MARK: PHContentEditingController

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == EmulsionFormat.adjustmentFormatIdentifier
            && adjustmentData.formatVersion == EmulsionFormat.formatVersion
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: NSImage) {
        input = contentEditingInput
        _ = view // make sure loadView ran
        var recipe = Recipe.neutral
        if let data = contentEditingInput.adjustmentData, canHandle(data),
           let decoded = try? Recipe.decode(data.data) {
            recipe = decoded
        }
        startRecipe = recipe
        guard let model else { return }
        model.recipe = recipe

        // Photos hands us the original when we can handle the adjustment data, so edits stay re-editable.
        // The orientation is applied once, from the file's own metadata (the same way the export reads it).
        if let url = contentEditingInput.fullSizeImageURL, model.loadSource(url: url) { return }
        // Fall back to the display-size image so the editor is never blank.
        if let cg = contentEditingInput.displaySizeImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.setSource(CIImage(cgImage: cg))
        } else if let cg = placeholderImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            model.setSource(CIImage(cgImage: cg))
        }
    }

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        let done = Unchecked(value: completionHandler)
        guard let model, let input, let inputURL = input.fullSizeImageURL else {
            completionHandler(nil)
            return
        }
        let recipe = model.recipe
        let renderer = model.renderer
        let output = PHContentEditingOutput(contentEditingInput: input)
        guard let data = try? recipe.encoded() else {
            completionHandler(nil)
            return
        }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: EmulsionFormat.adjustmentFormatIdentifier,
            formatVersion: EmulsionFormat.formatVersion,
            data: data)

        // Use the type Photos prefers when we can write it; JPEG otherwise.
        let writable: [UTType] = [.jpeg, .heic, .tiff]
        var type = UTType.jpeg
        if let preferred = output.defaultRenderedContentType, writable.contains(preferred) { type = preferred }
        let outputURL: URL
        do {
            outputURL = try output.renderedContentURL(for: type)
        } catch {
            completionHandler(nil)
            return
        }

        let out = Unchecked(value: output)
        let renderType = type
        exportTask = Task.detached(priority: .userInitiated) {
            var succeeded = false
            do {
                try renderer.export(recipe, inputURL: inputURL, outputURL: outputURL, type: renderType, quality: 0.92)
                succeeded = !Task.isCancelled
            } catch {
                succeeded = false
            }
            let result = succeeded
            await MainActor.run {
                done.value(result ? out.value : nil)
            }
        }
    }

    func cancelContentEditing() {
        exportTask?.cancel()
        model?.cancelWork()
    }

    var shouldShowCancelConfirmation: Bool {
        guard let model else { return false }
        return model.recipe != startRecipe
    }
}
