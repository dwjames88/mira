import Foundation
import Testing
@testable import MiraUpdates

extension StubbedNetwork {
@Suite("Download, verify and swap")
struct InstallTests {
    // MARK: Downloader

    @Test func downloadsWithProgressAndChecksDigest() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 & 0xff) })
        StubProtocol.install { _ in .data(payload, status: 200) }
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.zip")
        try payload.write(to: dir.appendingPathComponent("ref"))
        let digest = try UpdateDownloader.sha256Hex(ofFileAt: dir.appendingPathComponent("ref"))
        let asset = ReleaseAsset(name: "Mira-0.3.0.zip", downloadURL: URL(string: "https://github.com/dwjames88/mira/releases/download/v0.3.0/Mira-0.3.0.zip")!,
                                 size: Int64(payload.count), sha256: digest)
        let last = LockedValue<Int64>(0)
        try await UpdateDownloader.download(asset, to: file, configuration: StubProtocol.configuration) { received, _ in last.set(received) }
        #expect(try Data(contentsOf: file) == payload)
        #expect(last.get() == Int64(payload.count))
    }

    @Test func wrongDigestOrSizeIsRejectedAndDeleted() async throws {
        let payload = Data(repeating: 7, count: 10_000)
        StubProtocol.install { _ in .data(payload, status: 200) }
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://github.com/dwjames88/mira/releases/download/v0.3.0/Mira-0.3.0.zip")!
        let file = dir.appendingPathComponent("a.zip")
        await #expect(throws: UpdateError.digestMismatch) {
            try await UpdateDownloader.download(ReleaseAsset(name: "m.zip", downloadURL: url, size: 10_000, sha256: String(repeating: "0", count: 64)),
                                                to: file, configuration: StubProtocol.configuration) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: UpdateError.sizeMismatch(expected: 99, actual: 10_000)) {
            try await UpdateDownloader.download(ReleaseAsset(name: "m.zip", downloadURL: url, size: 99), to: file,
                                                configuration: StubProtocol.configuration) { _, _ in }
        }
    }

    @Test func downloadHttpErrorAndUntrustedHost() async throws {
        StubProtocol.install { _ in .data(Data("nope".utf8), status: 404) }
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = URL(string: "https://github.com/x/y/releases/download/v1/Mira-1.zip")!
        await #expect(throws: UpdateError.httpStatus(404)) {
            try await UpdateDownloader.download(ReleaseAsset(name: "Mira-1.zip", downloadURL: good, size: 4), to: dir.appendingPathComponent("a"),
                                                configuration: StubProtocol.configuration) { _, _ in }
        }
        await #expect(throws: UpdateError.noInstallableAsset) {
            try await UpdateDownloader.download(ReleaseAsset(name: "Mira-1.zip", downloadURL: URL(string: "https://example.com/Mira-1.zip")!, size: 4),
                                                to: dir.appendingPathComponent("b"), configuration: StubProtocol.configuration) { _, _ in }
        }
    }

    // MARK: Verifier

    @Test func rejectsUnsignedBundle() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(at: dir)
        guard case .signatureInvalid = captured(try BundleVerifier.verify(bundleAt: app, version: SemanticVersion("0.2.0"))) else {
            Issue.record("an unsigned app must be rejected"); return
        }
    }

    @Test func rejectsAdHocSignedBundleFromAnotherTeam() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(at: dir)
        #expect(try shell("/usr/bin/codesign", ["-s", "-", "--force", app.path]) == 0)
        guard case .signatureInvalid = captured(try BundleVerifier.verify(bundleAt: app, version: SemanticVersion("0.2.0"))) else {
            Issue.record("an ad-hoc signed app has no FieldFrames team and must be rejected"); return
        }
        // Same bundle, same signature, wrong team pinned.
        guard case .signatureInvalid = captured(try BundleVerifier.checkSignature(
            at: app, requirement: BundleVerifier.requirement(teamIdentifier: "AAAAAAAAAA"))) else {
            Issue.record("wrong team must be rejected"); return
        }
    }

    @Test func rejectsWrongIdentifierAndVersion() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let other = try makeApp(at: dir, name: "Other.app", identifier: "com.example.other")
        #expect(captured(try BundleVerifier.verify(bundleAt: other, version: nil)) == .bundleMismatch("identifier com.example.other is not com.fieldframes.mira"))
        let old = try makeApp(at: dir, name: "Old.app", version: "0.1.0")
        guard case .bundleMismatch = captured(try BundleVerifier.verify(bundleAt: old, version: SemanticVersion("0.2.0"))) else {
            Issue.record("wrong version must be rejected"); return
        }
        guard case .bundleMismatch = captured(try BundleVerifier.verify(bundleAt: dir.appendingPathComponent("Missing.app"), version: nil)) else {
            Issue.record("missing bundle must be rejected"); return
        }
    }

    @Test func signatureCheckDetectsTampering() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(at: dir)
        #expect(try shell("/usr/bin/codesign", ["-s", "-", "--force", app.path]) == 0)
        let requirement = #"identifier "com.fieldframes.mira""#
        try BundleVerifier.checkSignature(at: app, requirement: requirement)   // intact: accepted
        try "tampered".write(to: app.appendingPathComponent("Contents/Resources/marker.txt"), atomically: true, encoding: .utf8)
        guard case .signatureInvalid = captured(try BundleVerifier.checkSignature(at: app, requirement: requirement)) else {
            Issue.record("a modified resource must break the signature"); return
        }
    }

    // MARK: Extract and swap

    @Test func extractsASingleAppFromAZip() async throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp(at: dir.appendingPathComponent("src", isDirectory: true).createdDirectory())
        let zip = dir.appendingPathComponent("Mira-0.2.0.zip")
        #expect(try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]) == 0)
        let extracted = try await UpdateInstaller.extractApp(from: zip, into: dir.appendingPathComponent("out"))
        #expect(extracted.lastPathComponent == "Mira.app")
        #expect(try String(contentsOf: extracted.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "original")
    }

    @Test func extractRejectsGarbageAndMultipleApps() async throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.zip")
        try Data("not a zip".utf8).write(to: bad)
        await #expect(throws: UpdateError.self) { _ = try await UpdateInstaller.extractApp(from: bad, into: dir.appendingPathComponent("o1")) }
        let two = try dir.appendingPathComponent("two").createdDirectory()
        try makeApp(at: two, name: "A.app"); try makeApp(at: two, name: "B.app")
        let zip = dir.appendingPathComponent("two.zip")
        #expect(try shell("/usr/bin/ditto", ["-c", "-k", two.path, zip.path]) == 0)
        await #expect(throws: UpdateError.self) { _ = try await UpdateInstaller.extractApp(from: zip, into: dir.appendingPathComponent("o2")) }
    }

    @Test func swapReplacesTheOldBundleAndLeavesNoLitter() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let apps = try dir.appendingPathComponent("Applications").createdDirectory()
        let target = try makeApp(at: apps, marker: "old", )
        let newBundle = try makeApp(at: try dir.appendingPathComponent("stage").createdDirectory(), version: "0.3.0", marker: "new")
        let result = try UpdateInstaller.swap(newBundle: newBundle, over: target, disposeOld: .delete)
        #expect(result.standardizedFileURL == target.standardizedFileURL)
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "new")
        #expect(BundleVerifier.readInfo(ofBundleAt: target)?["CFBundleShortVersionString"] as? String == "0.3.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Mira.app"])
        #expect(FileManager.default.fileExists(atPath: newBundle.path))   // the extracted copy is the caller's to delete
    }

    @Test func failedStagedVerificationKeepsTheOldApp() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let apps = try dir.appendingPathComponent("Applications").createdDirectory()
        let target = try makeApp(at: apps, marker: "old")
        let newBundle = try makeApp(at: try dir.appendingPathComponent("stage").createdDirectory(), marker: "new")
        #expect(throws: UpdateError.signatureInvalid("nope")) {
            try UpdateInstaller.swap(newBundle: newBundle, over: target, disposeOld: .delete) { _ in throw UpdateError.signatureInvalid("nope") }
        }
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps.path) == ["Mira.app"])
    }

    @Test func swapIntoAnUnwritableFolderFailsCleanly() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Applications").path); try? FileManager.default.removeItem(at: dir) }
        let apps = try dir.appendingPathComponent("Applications").createdDirectory()
        let target = try makeApp(at: apps, marker: "old")
        let newBundle = try makeApp(at: try dir.appendingPathComponent("stage").createdDirectory(), marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        guard case .installFailed = captured(try UpdateInstaller.swap(newBundle: newBundle, over: target, disposeOld: .delete)) else {
            Issue.record("expected installFailed"); return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path)
        #expect(try String(contentsOf: target.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) == "old")
    }

    @Test func removesLeftoversAndSavesManualInstalls() throws {
        let dir = try makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent(".Mira-update-abc.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".Mira-previous-abc.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        UpdateInstaller.removeLeftovers(in: dir)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["Other.app"])

        let file = dir.appendingPathComponent("dl.zip"); try Data("zip".utf8).write(to: file)
        let downloads = dir.appendingPathComponent("Downloads")
        let first = try UpdateInstaller.saveForManualInstall(file, in: downloads, name: "Mira-0.3.0.zip")
        let second = try UpdateInstaller.saveForManualInstall(file, in: downloads, name: "Mira-0.3.0.zip")
        #expect(first.lastPathComponent == "Mira-0.3.0.zip")
        #expect(second.lastPathComponent == "Mira-0.3.0 2.zip")
    }
}
}

// MARK: Helpers

final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// The `UpdateError` an expression throws, or nil.
func captured(_ body: @autoclosure () throws -> some Any) -> UpdateError? {
    do { _ = try body(); return nil } catch { return error as? UpdateError }
}

extension URL {
    @discardableResult
    func createdDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
