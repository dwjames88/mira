import SwiftUI
import Testing
@testable import MiraUI

/// Headless renders of the update window to `<repo>/build/snapshots/`.
@MainActor
@Suite("Update notice snapshots", .serialized)
struct UpdateNoticeSnapshotTests {
    static let info = UpdateNoticeInfo(version: "0.3.0", current: "0.2.0", notes: [
        .heading("Added"),
        .bullet("Presets: save and recall a whole look, with an editor tab."),
        .bullet("Check for Updates\u{2026} in the Mira menu, with automatic checks at launch."),
        .heading("Changed"),
        .bullet("Previews render at canvas resolution from a cached `base`: median frame **12 ms to 5 ms**."),
        .heading("Fixed"),
        .bullet("Scroll-wheel pan over the zoomed canvas."),
    ])

    @Test func renderUpdateNotice() throws {
        FieldFramesTheme.registerFonts()
        let size = CGSize(width: UpdateNoticeView.width, height: FieldFramesTheme.rows(26))
        for (scheme, tag) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            try SnapshotTests.writePNG(UpdateNoticeView(phase: .available(Self.info)), size: size, scheme: scheme, name: "update-available-\(tag)")
        }
        try SnapshotTests.writePNG(UpdateNoticeView(phase: .downloading(Self.info, received: 31_400_000, total: 86_304_083)),
                                   size: size, scheme: .dark, name: "update-downloading-dark")
        try SnapshotTests.writePNG(UpdateNoticeView(phase: .upToDate(current: "0.2.0")), size: size, scheme: .dark, name: "update-uptodate-dark")
        try SnapshotTests.writePNG(UpdateNoticeView(phase: .failed("Mira could not reach GitHub. Check your internet connection and try again.", info: nil)),
                                   size: size, scheme: .dark, name: "update-failed-dark")
        try SnapshotTests.writePNG(UpdateNoticeView(phase: .installed(Self.info, note: "This build is not notarized, so macOS asks you to approve it once: right-click Mira in Applications, choose Open, then Open.")),
                                   size: size, scheme: .dark, name: "update-installed-dark")
        try SnapshotTests.writePNG(UpdateNoticeView(phase: .savedForManualInstall(Self.info, fileName: "Mira-0.3.0.zip",
                                                                                    reason: "Mira was not given access to the Applications folder, so it could not replace itself.")),
                                   size: size, scheme: .dark, name: "update-saved-dark")
    }

    @Test func downloadProgressText() {
        #expect(UpdateNoticeView.byteText(0, 0) == "Zero KB downloaded")
        #expect(UpdateNoticeView.byteText(31_400_000, 86_304_083).contains(" of "))
    }

    @Test func inlineMarkdownRendersAndFallsBack() {
        #expect(String(UpdateNoticeView.inline("a **b** `c`").characters) == "a b c")
        #expect(String(UpdateNoticeView.inline("plain").characters) == "plain")
    }
}
