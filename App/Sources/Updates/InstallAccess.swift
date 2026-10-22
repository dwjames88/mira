import AppKit
import MiraUpdates
import os

/// Permission for the sandboxed app to write the folder it lives in (normally /Applications).
///
/// The App Sandbox cannot write outside the container, but a folder the user picks in an open panel is
/// writable (`user-selected.read-write`), and a security-scoped bookmark (`bookmarks.app-scope`) keeps that
/// grant for later launches. So the first install asks once: "Allow Mira to update itself in this folder".
@MainActor
enum InstallAccess {
    private static let bookmarkKey = "mira.updates.installFolderBookmark"
    private static let logger = Logger(subsystem: "com.fieldframes.mira", category: "updates")

    /// A folder the app may write while this value is alive. Call `end()` when done.
    struct Grant {
        let folder: URL
        let scopedURL: URL
        let isScoped: Bool
        func end() { if isScoped { scopedURL.stopAccessingSecurityScopedResource() } }
    }

    /// `nil` when the user declines or the folder still is not writable.
    static func acquire(forBundleAt bundleURL: URL) -> Grant? {
        let folder = bundleURL.deletingLastPathComponent().standardizedFileURL
        if let grant = storedGrant(covering: folder) { return grant }
        // Not sandboxed (a debug build run from Xcode) and already writable: no panel needed.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
           FileManager.default.isWritableFile(atPath: folder.path) {
            return Grant(folder: folder, scopedURL: folder, isScoped: false)
        }
        return askUser(folder: folder)
    }

    /// Forget the stored grant (the next install asks again).
    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func storedGrant(covering folder: URL) -> Grant? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              covers(url, folder), url.startAccessingSecurityScopedResource() else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { url.stopAccessingSecurityScopedResource(); return nil }
        return Grant(folder: folder, scopedURL: url, isScoped: true)
    }

    private static func askUser(folder: URL) -> Grant? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.title = "Allow Mira to Update Itself"
        panel.message = "Allow Mira to update itself in this folder"
        panel.prompt = "Allow"
        NSApp.activate()
        guard panel.runModal() == .OK, let chosen = panel.url?.standardizedFileURL else { return nil }
        guard covers(chosen, folder) else {
            logger.info("Install folder grant refused: \(chosen.path, privacy: .public) does not contain \(folder.path, privacy: .public)")
            return nil
        }
        guard chosen.startAccessingSecurityScopedResource() else { return nil }
        if let data = try? chosen.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            chosen.stopAccessingSecurityScopedResource()
            return nil
        }
        return Grant(folder: folder, scopedURL: chosen, isScoped: true)
    }

    /// `granted` is the folder itself or one of its ancestors.
    nonisolated static func covers(_ granted: URL, _ folder: URL) -> Bool {
        let g = granted.standardizedFileURL.path, f = folder.standardizedFileURL.path
        return f == g || f.hasPrefix(g.hasSuffix("/") ? g : g + "/")
    }
}
