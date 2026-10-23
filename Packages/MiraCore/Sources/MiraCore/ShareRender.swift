import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Renders the current look to a temporary file for the system share sheet. The pixels and the
/// metadata go through `Renderer.export`, so a shared picture matches File > Export exactly (full
/// size, orientation 1, source metadata copied, same colour-space rule).
public enum ShareRender {
    /// Every staging directory starts with this; stale ones from earlier launches are removed.
    public static let directoryPrefix = "MiraShareImage-"

    /// "<base name> - Mira.jpg": characters a file name cannot hold become "-".
    public static func fileName(baseName: String, type: UTType) -> String {
        let cleaned = baseName.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        let base = cleaned.trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Photo" : base) + " - Mira." + fileExtension(for: type)
    }

    /// "jpg" (not "jpeg"), "heic", "tiff": the extensions File > Export uses.
    public static func fileExtension(for type: UTType) -> String {
        type == .jpeg ? "jpg" : (type.preferredFilenameExtension ?? "jpg")
    }

    /// Renders `recipe` over the full-size `source` into `directory` and returns the file.
    public static func render(
        _ recipe: Recipe, source: CIImage, metadataFrom: URL?, baseName: String,
        type: UTType, quality: Double, colorSpace: CGColorSpace? = nil,
        renderer: Renderer, directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(baseName: baseName, type: type))
        try renderer.export(recipe, source: source, metadataFrom: metadataFrom, outputURL: url,
                            type: type, quality: quality, colorSpace: colorSpace)
        return url
    }

    /// Owns the per-launch staging directory. Each share gets a fresh sub-folder (so the file keeps
    /// its readable name); the previous one is removed then, and everything on the next launch.
    public final class Staging: @unchecked Sendable {
        public static let shared = Staging()

        private let lock = NSLock()
        private let parent: URL
        private var launchDirectory: URL?
        private var current: URL?

        public init(parent: URL = FileManager.default.temporaryDirectory) {
            self.parent = parent
        }

        /// Removes staging directories left by earlier launches. Safe to call from any thread.
        public func removeStale() {
            lock.lock(); defer { lock.unlock() }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names where name.hasPrefix(directoryPrefix) {
                let url = parent.appendingPathComponent(name, isDirectory: true)
                if url != launchDirectory { try? FileManager.default.removeItem(at: url) }
            }
        }

        /// A new empty directory for one share; the one from the previous share is deleted.
        public func nextDirectory() throws -> URL {
            lock.lock(); defer { lock.unlock() }
            if launchDirectory == nil {
                launchDirectory = parent.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
            }
            if let current { try? FileManager.default.removeItem(at: current) }
            let dir = launchDirectory!.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            current = dir
            return dir
        }
    }
}
