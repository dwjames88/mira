import Foundation
import Testing
@testable import MiraUpdates

/// End to end against the real GitHub release, run by hand:
///     MIRA_LIVE_UPDATE=1 swift test --filter LiveUpdateTests
/// Everything happens in temp directories; no installed app is touched.
@Suite("Live update (MIRA_LIVE_UPDATE=1)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MIRA_LIVE_UPDATE"] == "1"))
struct LiveUpdateTests {
    @Test func checkDownloadVerifySwapAgainstRealRelease() async throws {
        let fm = FileManager.default
        let root = try makeTempDirectory(); defer { try? fm.removeItem(at: root) }
        func ms(_ since: ContinuousClock.Instant) -> String {
            let d = since.duration(to: .now)
            return String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        let clock = ContinuousClock()

        // 1. Check, pretending to run Mira 0.1.0.
        var t = clock.now
        let prefs = UpdatePreferences(defaults: scratchDefaults())
        let report = await UpdateChecker().check(current: SemanticVersion("0.1.0")!, trigger: .manual, preferences: prefs)
        guard case .available(let release) = report else { Issue.record("expected an update, got \(report)"); return }
        print("LIVE check: \(ms(t)) -> \(release.tag) \"\(release.title)\" \(release.assets.count) assets, notes \(release.notes.count) chars")
        #expect(release.version == SemanticVersion("0.2.0"))
        // The same release is not news to a 0.2.0 install.
        let same = await UpdateChecker().check(current: SemanticVersion("0.2.0")!, trigger: .manual, preferences: prefs)
        print("LIVE check as 0.2.0 -> \(same)")
        guard case .upToDate = same else { Issue.record("0.2.0 must be up to date"); return }

        // 2. Asset selection.
        let asset = try #require(release.installableAsset)
        print("LIVE asset: \(asset.name), \(asset.size) bytes, sha256 \(asset.sha256 ?? "(none)")")
        #expect(asset.name == "Mira-0.2.0.zip")

        // 3. Real download with progress.
        let zip = root.appendingPathComponent("download/\(asset.name)")
        let reports = LockedValue<Int>(0)
        let lastReceived = LockedValue<Int64>(0)
        t = clock.now
        try await UpdateDownloader.download(asset, to: zip) { received, _ in
            reports.set(reports.get() + 1); lastReceived.set(received)
        }
        let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("LIVE download: \(ms(t)), \(size) bytes on disk, \(reports.get()) progress callbacks, last \(lastReceived.get()) bytes, size+sha256 verified")
        #expect(size == asset.size)
        #expect(reports.get() > 5)

        // 4. Extract.
        t = clock.now
        let app = try await UpdateInstaller.extractApp(from: zip, into: root.appendingPathComponent("extracted"))
        print("LIVE extract: \(ms(t)) -> \(app.path)")

        // 5. Verify: identifier, version, Apple anchor + Team ID, nested extension, strict.
        t = clock.now
        try BundleVerifier.verify(bundleAt: app, version: SemanticVersion("0.2.0"))
        print("LIVE verify: ACCEPTED in \(ms(t)) (id \(BundleVerifier.bundleIdentifier), team \(BundleVerifier.teamIdentifier), version 0.2.0)")
        #expect(captured(try BundleVerifier.verify(bundleAt: app, version: SemanticVersion("0.3.0"))) != nil)   // wrong version expectation

        // 6. Negative: a tampered copy.
        let tampered = try root.appendingPathComponent("tampered").createdDirectory().appendingPathComponent("Mira.app")
        try fm.copyItem(at: app, to: tampered)
        let resources = tampered.appendingPathComponent("Contents/Resources")
        let file = try #require(try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil).first { !$0.hasDirectoryPath })
        try Data("tampered".utf8).write(to: file)
        let rejection = captured(try BundleVerifier.verify(bundleAt: tampered, version: SemanticVersion("0.2.0")))
        print("LIVE verify tampered (\(file.lastPathComponent) rewritten): REJECTED -> \(rejection.map { "\($0)" } ?? "NOT REJECTED")")
        guard case .signatureInvalid = rejection else { Issue.record("tampered copy must be rejected, got \(String(describing: rejection))"); return }

        // 7. Swap into a temp "Applications" holding a fake old Mira.
        let apps = try root.appendingPathComponent("Applications").createdDirectory()
        let old = try makeApp(at: apps, version: "0.1.0", marker: "old")
        t = clock.now
        let installed = try UpdateInstaller.swap(newBundle: app, over: old, disposeOld: .delete) { staged in
            try BundleVerifier.verify(bundleAt: staged, version: SemanticVersion("0.2.0"))
        }
        let version = BundleVerifier.readInfo(ofBundleAt: installed)?["CFBundleShortVersionString"] as? String
        print("LIVE swap (temp dir): \(ms(t)) -> \(installed.path), version \(version ?? "?"), folder now \(try fm.contentsOfDirectory(atPath: apps.path))")
        #expect(version == "0.2.0")
        try BundleVerifier.verify(bundleAt: installed, version: SemanticVersion("0.2.0"))
    }
}
