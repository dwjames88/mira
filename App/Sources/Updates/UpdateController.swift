import AppKit
import MiraUI
import MiraUpdates
import Observation
import os

/// Runs the update flow and owns the update window: launch check, manual check, download, verify, install, relaunch.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    private(set) var phase: UpdateNoticePhase = .checking

    @ObservationIgnored private let logger = Logger(subsystem: "com.fieldframes.mira", category: "updates")
    @ObservationIgnored private let preferences = UpdatePreferences()
    @ObservationIgnored private let checker = UpdateChecker(userAgent: UpdateController.userAgent)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var release: Release?
    @ObservationIgnored private var savedFile: URL?
    @ObservationIgnored private var installedBundle: URL?
    @ObservationIgnored private var windowController: UpdateWindowController?

    static var userAgent: String {
        "Mira-Updater/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
    }

    var currentVersion: SemanticVersion {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
            ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    private var isBusy: Bool {
        switch phase {
        case .downloading, .working: true
        default: false
        }
    }

    // MARK: Checks

    /// Background check once per launch. Shows nothing unless there is a newer release.
    func checkAtLaunch() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // Let the window and library settle first; the check never competes with launch work.
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            let report = await self.checker.check(current: self.currentVersion, trigger: .launch, preferences: self.preferences)
            switch report {
            case .available(let release):
                self.offer(release)
                self.showWindow(activate: false)
            case .upToDate(let current, let latest):
                self.logger.info("Update check: \(current.description, privacy: .public) is current (latest \(latest.description, privacy: .public))")
                self.task = nil
            case .skipped(let release):
                self.logger.info("Update check: \(release.version.description, privacy: .public) is skipped by the user")
                self.task = nil
            case .notDue:
                self.task = nil
            case .failed(let error), .silentFailure(let error):
                self.logger.info("Update check failed quietly: \(error.description, privacy: .public)")
                self.task = nil
            }
        }
    }

    /// Mira > Check for Updates...: ignores the throttle and always says something.
    func checkManually() {
        if let controller = windowController, isBusy { controller.show(activate: true); return }
        task?.cancel()
        phase = .checking
        showWindow(activate: true)
        task = Task { [weak self] in
            guard let self else { return }
            let report = await self.checker.check(current: self.currentVersion, trigger: .manual, preferences: self.preferences)
            guard !Task.isCancelled else { return }
            switch report {
            case .available(let release), .skipped(let release):
                self.offer(release)
            case .upToDate(let current, _):
                self.phase = .upToDate(current: current.description)
                self.task = nil
            case .failed(let error), .silentFailure(let error):
                self.phase = .failed(error.userMessage, info: nil)
                self.task = nil
            case .notDue:
                self.task = nil
            }
        }
    }

    private func offer(_ release: Release) {
        self.release = release
        phase = .available(info(for: release))
        task = nil
    }

    private func info(for release: Release) -> UpdateNoticeInfo {
        let blocks = ReleaseNotes.parse(ReleaseNotes.updateNotes(from: release.notes)).map { block -> UpdateNoticeBlock in
            switch block {
            case .heading(let text): .heading(text)
            case .bullet(let text): .bullet(text)
            case .paragraph(let text): .paragraph(text)
            }
        }
        return UpdateNoticeInfo(version: release.version.description, current: currentVersion.description, notes: blocks)
    }

    // MARK: Actions

    var actions: UpdateNoticeActions {
        UpdateNoticeActions(
            install: { [weak self] in self?.installOrRelaunch() },
            later: { [weak self] in self?.dismiss() },
            skip: { [weak self] in self?.skipVersion() },
            cancel: { [weak self] in self?.cancel() },
            dismiss: { [weak self] in self?.dismiss() },
            openReleasePage: { [weak self] in if let url = self?.release?.pageURL { NSWorkspace.shared.open(url) } },
            reveal: { [weak self] in self?.reveal() })
    }

    func dismiss() {
        windowController?.close()
    }

    /// Stops a check or download. Back to the offer if there is one, else closes the window.
    func cancel() {
        abandonWork()
        if release == nil { windowController?.close() }
    }

    /// Called when the window closes while work is running.
    func abandonWork() {
        task?.cancel()
        task = nil
        if let release, case .downloading = phase { phase = .available(info(for: release)) }
    }

    func skipVersion() {
        if let release { preferences.skippedVersion = release.version }
        dismiss()
    }

    private func reveal() {
        if let url = savedFile ?? installedBundle { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func installOrRelaunch() {
        if case .installed = phase { relaunch(); return }
        install()
    }

    // MARK: Install

    private func install() {
        guard let release, task == nil, let asset = release.installableAsset else { return }
        let info = info(for: release)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runInstall(release: release, asset: asset, info: info)
            } catch let error as UpdateError where error == .cancelled {
                self.phase = .available(info)
            } catch {
                let failure = error as? UpdateError ?? .installFailed(error.localizedDescription)
                self.logger.error("Update failed: \(failure.description, privacy: .public)")
                self.phase = .failed(failure.userMessage, info: info)
            }
            self.task = nil
        }
    }

    private func runInstall(release: Release, asset: ReleaseAsset, info: UpdateNoticeInfo) async throws {
        let fm = FileManager.default
        let work = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MiraUpdate", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download, with progress.
        phase = .downloading(info, received: 0, total: asset.size)
        let archive = work.appendingPathComponent(asset.name)
        try await UpdateDownloader.download(asset, to: archive) { received, total in
            Task { @MainActor in
                if case .downloading = UpdateController.shared.phase {
                    UpdateController.shared.phase = .downloading(info, received: received, total: total)
                }
            }
        }

        // A disk image cannot be installed in place: hand it over.
        guard asset.isZip else {
            try handOff(archive: archive, asset: asset, info: info, reason: "This release only comes as a disk image, which Mira cannot install by itself.")
            return
        }

        // 2. Unpack and verify: bundle id, version, and a valid FieldFrames signature.
        phase = .working(info, status: "Verifying", detail: nil)
        let app = try await UpdateInstaller.extractApp(from: archive, into: work.appendingPathComponent("extracted"))
        try BundleVerifier.verify(bundleAt: app, version: release.version)
        try Task.checkCancellation()

        // 3. Permission to write the folder Mira lives in.
        let target = Bundle.main.bundleURL
        guard let grant = InstallAccess.acquire(forBundleAt: target) else {
            try handOff(archive: archive, asset: asset, info: info,
                        reason: "Mira was not given access to its folder, so it could not replace itself. The download was verified.")
            return
        }
        defer { grant.end() }

        // 4. Swap atomically, off the main thread; the old copy goes to the Trash.
        phase = .working(info, status: "Installing", detail: nil)
        let version = release.version
        let installed = try await Task.detached(priority: .userInitiated) {
            UpdateInstaller.removeLeftovers(in: grant.folder)
            return try UpdateInstaller.swap(newBundle: app, over: target) { staged in
                try BundleVerifier.verify(bundleAt: staged, version: version)
            }
        }.value
        installedBundle = installed

        // The sandbox cannot clear com.apple.quarantine, so a sandboxed install leaves the new app quarantined.
        let quarantined = UpdateInstaller.stripQuarantine(at: installed) > 0
        let note = quarantined
            ? "This build is not notarized, so macOS asks you to approve the new version once when it opens: right-click Mira in Applications, choose Open, then Open (or System Settings \u{25B8} Privacy & Security \u{25B8} Open Anyway)."
            : nil
        phase = .installed(info, note: note)
        if note == nil { relaunch() }
    }

    private func handOff(archive: URL, asset: ReleaseAsset, info: UpdateNoticeInfo, reason: String) throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let saved = try UpdateInstaller.saveForManualInstall(archive, in: downloads, name: asset.name)
        savedFile = saved
        phase = .savedForManualInstall(info, fileName: saved.lastPathComponent, reason: reason)
        NSWorkspace.shared.activateFileViewerSelecting([saved])
    }

    // MARK: Relaunch

    private func relaunch() {
        guard let installed = installedBundle else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.logger.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                    let info = self.release.map(self.info(for:))
                    self.phase = .failed("The new version is installed but macOS did not open it (\(error.localizedDescription)). Open Mira from Applications; if macOS blocks it, right-click Mira and choose Open.", info: info)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Window

    private func showWindow(activate: Bool) {
        if windowController == nil { windowController = UpdateWindowController(controller: self) }
        windowController?.show(activate: activate)
    }
}
