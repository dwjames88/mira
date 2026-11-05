import Foundation
import Testing
@testable import MiraUpdates

/// The v1.0.0 release as GitHub's API will return it (`Fixtures/release-v1.0.0.json`, shaped like the real
/// v0.2.0 response). Pins what every shipped updater (v0.3.0 and later share one MiraUpdates) must see.
/// docs/UPDATES.md has the contract; scripts/updater-compat.sh runs the same JSON through an older tag's code.
extension StubbedNetwork {
@Suite("Release v1.0.0 fixture")
struct ReleaseV1FixtureTests {
    private func release() throws -> Release { try Release.decode(Fixture.data("release-v1.0.0")) }

    @Test func decodesTheContract() throws {
        let release = try release()
        #expect(release.tag == "v1.0.0")
        #expect(release.version == SemanticVersion("1.0.0"))
        #expect(release.title == "Mira 1.0.0")
        #expect(!release.isPrerelease)
        #expect(release.pageURL.absoluteString == "https://github.com/dwjames88/mira/releases/tag/v1.0.0")
        #expect(release.assets.map(\.name).sorted() == ["Mira-1.0.0.dmg", "Mira-1.0.0.zip"])
    }

    @Test func picksTheZipAndAcceptsItsURL() throws {
        let release = try release()
        let zip = try #require(release.zipAsset)
        #expect(zip.name == "Mira-1.0.0.zip")
        #expect(zip.downloadURL.absoluteString == "https://github.com/dwjames88/mira/releases/download/v1.0.0/Mira-1.0.0.zip")
        #expect(Release.isTrustedDownloadURL(zip.downloadURL))
        #expect(zip.size > 0)
        #expect(zip.sha256?.count == 64)
        #expect(release.installableAsset == zip)
        #expect(release.diskImageAsset?.name == "Mira-1.0.0.dmg")
    }

    @Test func downloadHostsGitHubRedirectsTo() {
        // browser_download_url 302s to one of these; the allow-list covers every *.githubusercontent.com host.
        for host in ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"] {
            #expect(Release.isTrustedDownloadURL(URL(string: "https://\(host)/x")!), "\(host)")
        }
    }

    @Test(arguments: ["0.3.0", "0.3.1", "0.4.0", "0.5.0", "0.99.9", "1.0.0-rc.1"])
    func isNewerThanEveryEarlierBuild(installed: String) async throws {
        #expect(try release().version > SemanticVersion(installed)!)
        let body = try Fixture.data("release-v1.0.0")
        StubProtocol.install { _ in .data(body, status: 200) }
        let checker = UpdateChecker(session: StubProtocol.session, userAgent: "Mira-Updater/test")
        let report = await checker.check(current: SemanticVersion(installed)!, trigger: .manual,
                                         preferences: UpdatePreferences(defaults: scratchDefaults()))
        guard case .available(let found) = report else { Issue.record("expected .available for \(installed), got \(report)"); return }
        #expect(found.installableAsset?.name == "Mira-1.0.0.zip")
    }

    @Test func isNotNewsTo1_0_0Itself() async throws {
        let body = try Fixture.data("release-v1.0.0")
        StubProtocol.install { _ in .data(body, status: 200) }
        let checker = UpdateChecker(session: StubProtocol.session, userAgent: "Mira-Updater/test")
        let report = await checker.check(current: SemanticVersion("1.0.0")!, trigger: .manual,
                                         preferences: UpdatePreferences(defaults: scratchDefaults()))
        #expect(report == .upToDate(current: SemanticVersion("1.0.0")!, latest: SemanticVersion("1.0.0")!))
    }
}
}
