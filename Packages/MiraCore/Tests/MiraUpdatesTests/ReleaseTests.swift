import Foundation
import Testing
@testable import MiraUpdates

@Suite("Release parsing and asset selection")
struct ReleaseTests {
    @Test func parsesTheRealV020Response() throws {
        let release = try Release.decode(Fixture.data("release-v0.2.0"))
        #expect(release.tag == "v0.2.0")
        #expect(release.version == SemanticVersion("0.2.0"))
        #expect(release.title == "Mira 0.2.0")
        #expect(release.pageURL.absoluteString == "https://github.com/dwjames88/mira/releases/tag/v0.2.0")
        #expect(!release.isPrerelease)
        #expect(release.notes.contains("### Added"))
        #expect(release.assets.map(\.name).sorted() == ["Mira-0.2.0.dmg", "Mira-0.2.0.zip"])
        let zip = try #require(release.zipAsset)
        #expect(zip.name == "Mira-0.2.0.zip")
        #expect(zip.size == 86_304_083)
        #expect(zip.sha256 == "9ecca86ca91a29f7a87e631d80b6292a0f3e573d1f1683d0e28548daf8df5696")
        #expect(zip.downloadURL.absoluteString == "https://github.com/dwjames88/mira/releases/download/v0.2.0/Mira-0.2.0.zip")
        #expect(release.diskImageAsset?.name == "Mira-0.2.0.dmg")
        #expect(release.installableAsset == zip)
    }

    @Test func rejectsMalformedResponses() {
        #expect(throws: UpdateError.self) { try Release.decode(Data("{}".utf8)) }
        #expect(throws: UpdateError.self) { try Release.decode(Data("not json".utf8)) }
        let badTag = #"{"tag_name":"nightly","html_url":"https://github.com/x/y/releases/tag/nightly"}"#
        #expect(throws: UpdateError.self) { try Release.decode(Data(badTag.utf8)) }
    }

    private func release(assets: [(String, String)]) -> Release {
        Release(tag: "v0.3.0", version: SemanticVersion("0.3.0")!, title: "Mira 0.3.0", notes: "",
                pageURL: URL(string: "https://github.com/dwjames88/mira/releases/tag/v0.3.0")!,
                assets: assets.map { ReleaseAsset(name: $0.0, downloadURL: URL(string: $0.1)!, size: 10) })
    }

    @Test func prefersTheVersionedZipThenAnyMiraZipThenDmg() {
        let base = "https://github.com/dwjames88/mira/releases/download/v0.3.0/"
        let both = release(assets: [("Mira-0.3.0.dmg", base + "Mira-0.3.0.dmg"), ("Mira.zip", base + "Mira.zip"), ("Mira-0.3.0.zip", base + "Mira-0.3.0.zip")])
        #expect(both.installableAsset?.name == "Mira-0.3.0.zip")
        let loose = release(assets: [("Mira-0.3.0.dmg", base + "Mira-0.3.0.dmg"), ("Mira-universal.zip", base + "Mira-universal.zip")])
        #expect(loose.installableAsset?.name == "Mira-universal.zip")
        let dmgOnly = release(assets: [("Mira-0.3.0.dmg", base + "Mira-0.3.0.dmg"), ("checksums.txt", base + "checksums.txt")])
        #expect(dmgOnly.zipAsset == nil)
        #expect(dmgOnly.installableAsset?.name == "Mira-0.3.0.dmg")
        #expect(release(assets: [("notes.txt", base + "notes.txt")]).installableAsset == nil)
    }

    @Test func refusesUntrustedDownloadHosts() {
        let evil = release(assets: [("Mira-0.3.0.zip", "https://evil.example.com/Mira-0.3.0.zip"),
                                    ("Mira.zip", "http://github.com/Mira.zip")])
        #expect(evil.installableAsset == nil)
        #expect(Release.isTrustedDownloadURL(URL(string: "https://objects.githubusercontent.com/x")!))
        #expect(!Release.isTrustedDownloadURL(URL(string: "https://github.com.evil.com/x")!))
        #expect(!Release.isTrustedDownloadURL(URL(string: "https://notgithub.com/x")!))
    }

    @Test func notesDropTheInstallBoilerplateAndParseToBlocks() throws {
        let release = try Release.decode(Fixture.data("release-v0.2.0"))
        let notes = ReleaseNotes.updateNotes(from: release.notes)
        #expect(!notes.contains("## Install"))
        #expect(!notes.contains("Right-click Mira"))
        let blocks = ReleaseNotes.parse(notes)
        #expect(blocks.first == .heading("Added"))
        #expect(blocks.contains(.heading("Fixed")))
        #expect(blocks.contains(.bullet("Scroll-wheel pan over the zoomed canvas.")))
        #expect(ReleaseNotes.parse("Plain line one\nline two\n\n- a\n  wrapped") ==
                [.paragraph("Plain line one line two"), .bullet("a wrapped")])
    }
}
