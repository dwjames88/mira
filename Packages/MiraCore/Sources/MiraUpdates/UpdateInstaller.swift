import Darwin
import Foundation

/// Unpacks a verified archive and swaps the new bundle in for the old one. Everything here works on paths it is
/// given, so tests drive it with temp directories.
public enum UpdateInstaller {
    /// Unzips with `/usr/bin/ditto -x -k` (works inside the App Sandbox: verified) and returns the single
    /// top-level `.app`.
    public static func extractApp(from archive: URL, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent(".ditto.log")
        let status = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], stderrTo: log)
        guard status == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError.archiveInvalid(message.isEmpty ? "ditto exited with status \(status)" : message)
        }
        try? fm.removeItem(at: log)
        let entries = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let content = entries.filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        let apps = content.filter { $0.hasSuffix(".app") }
        guard apps.count == 1, content.count == 1 else {
            throw UpdateError.archiveInvalid("expected exactly one top-level .app, found \(content.count) item(s)")
        }
        return directory.appendingPathComponent(apps[0], isDirectory: true)
    }

    public enum OldBundleDisposal: Sendable { case trash, delete }

    /// Replaces `target` with a copy of `newBundle`. The copy is staged next to `target` (same volume, so the
    /// final step is an atomic exchange), re-verified through `verifyStaged`, then swapped in; the old bundle
    /// goes to the Trash (or is deleted). If anything fails `target` is left untouched.
    /// Returns the URL of the installed bundle.
    @discardableResult
    public static func swap(
        newBundle: URL, over target: URL, disposeOld: OldBundleDisposal = .trash,
        verifyStaged: ((URL) throws -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let token = UUID().uuidString.prefix(8)
        let staged = directory.appendingPathComponent(".\(stagedPrefix)\(token).app", isDirectory: true)
        let backupName = ".\(previousPrefix)\(token).app"
        let backup = directory.appendingPathComponent(backupName, isDirectory: true)
        do {
            try fm.copyItem(at: newBundle, to: staged)
            try verifyStaged?(staged)
        } catch let error as UpdateError {
            try? fm.removeItem(at: staged)
            throw error
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError.installFailed("cannot stage the new app: \(error.localizedDescription)")
        }
        do {
            let result = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: backupName, options: [.withoutDeletingBackupItem])
            if fm.fileExists(atPath: backup.path) {
                switch disposeOld {
                case .trash:
                    do { try fm.trashItem(at: backup, resultingItemURL: nil) } catch { try? fm.removeItem(at: backup) }
                case .delete:
                    try? fm.removeItem(at: backup)
                }
            }
            return result ?? target
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError.installFailed("cannot replace the app: \(error.localizedDescription)")
        }
    }

    static let stagedPrefix = "Mira-update-"
    static let previousPrefix = "Mira-previous-"

    /// Removes staging leftovers (`.Mira-update-*`, `.Mira-previous-*`) a crash left in `directory`.
    public static func removeLeftovers(in directory: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(".\(stagedPrefix)") || name.hasPrefix(".\(previousPrefix)") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Best effort `com.apple.quarantine` removal. Returns how many items kept it. Outside the sandbox this
    /// clears all of them; inside the App Sandbox the kernel refuses (EPERM) and every file the app writes is
    /// quarantined, which is why the first launch of an installed update may need the user's approval.
    @discardableResult
    public static func stripQuarantine(at root: URL) -> Int {
        let fm = FileManager.default
        var paths = [root.path]
        paths += ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? []).map { root.appendingPathComponent($0).path }
        var remaining = 0
        for path in paths {
            if getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0 { continue }
            if removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 { remaining += 1 }
        }
        return remaining
    }

    /// Copies a verified download to `folder` for a manual install, avoiding name clashes.
    public static func saveForManualInstall(_ file: URL, in folder: URL, name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(name)
        var n = 2
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        do { try fm.copyItem(at: file, to: destination) }
        catch { throw UpdateError.installFailed("cannot save the download: \(error.localizedDescription)") }
        return destination
    }

    private static func run(_ path: String, _ arguments: [String], stderrTo log: URL) async throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: log)
        defer { try? errHandle.close() }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errHandle
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: UpdateError.archiveInvalid("cannot run ditto: \(error.localizedDescription)")) }
        }
    }
}
