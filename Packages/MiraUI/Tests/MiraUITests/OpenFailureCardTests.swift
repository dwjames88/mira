import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Open failure card", .serialized)
struct OpenFailureCardTests {
    @Test func defaultMessage() {
        #expect(FFOpenFailureCard.defaultMessage == "Photos didn't hand over this photo.")
        #expect(!FFOpenFailureCard.defaultMessage.contains("\u{2019}"))
    }

    @Test func renderOpenFailureCard() throws {
        FieldFramesTheme.registerFonts()
        let card = FFOpenFailureCard(detail: "CHECK YOUR ICLOUD CONNECTION", onRetry: {}, onBack: {})
            .padding(FieldFramesTheme.cells(6))
            .background(FieldFramesTheme.ink)
        try SnapshotTests.writePNG(card, size: CGSize(width: FieldFramesTheme.cells(60), height: FieldFramesTheme.rows(16)),
                                   scheme: .dark, name: "open-failure-card")
    }
}
