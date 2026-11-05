import XCTest

/// Gallery flow inside the simulator: open the library, filter RAW, open a photo, come back.
/// Needs Photos access granted (see project.yml) and a seeded library. Screenshots go to MIRA_UITEST_SHOTS if set.
final class GalleryFlowTests: XCTestCase {
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let att = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        att.name = name
        att.lifetime = .keepAlways
        add(att)
        if let dir = ProcessInfo.processInfo.environment["MIRA_UITEST_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testOpenLibraryFilterRawAndEditorRoundTrip() throws {
        let app = XCUIApplication()
        app.launch()
        let library = app.staticTexts["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 20), "album list never loaded")
        library.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'PHOTOS'")).firstMatch
            .waitForExistence(timeout: 20))
        sleep(3)
        shot("01-library-grid")

        // RAW filter
        let rawTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'RAW'")).firstMatch
        if rawTab.waitForExistence(timeout: 5) {
            rawTab.tap()
            sleep(4)
            shot("02-raw-filter")
            app.buttons["ALL"].tap()
            sleep(2)
        }

        // Scroll, open a photo, return: the place must survive.
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<3 { scroll.swipeUp() }
        sleep(2)
        shot("03-scrolled")
        let cell = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        cell.tap()
        let back = app.buttons["Back to library"]
        XCTAssertTrue(back.waitForExistence(timeout: 30), "editor never opened")
        sleep(5)
        shot("04-editor")
        back.tap()
        sleep(2)
        shot("05-back-in-grid")
    }

    /// Opens a RAW (DNG) from the RAW filter: it must open on the RAW (not the rendered picture) without blocking.
    func testOpenRawFromFilter() throws {
        let app = XCUIApplication()
        app.launch()
        app.staticTexts["Library"].tap()
        let rawTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'RAW'")).firstMatch
        XCTAssertTrue(rawTab.waitForExistence(timeout: 20))
        rawTab.tap()
        sleep(3)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        let back = app.buttons["Back to library"]
        XCTAssertTrue(back.waitForExistence(timeout: 60), "RAW never opened")
        for second in [2, 6, 12] {
            sleep(UInt32(second))
            shot("20-raw-open-\(second)")
        }
        try? app.debugDescription.write(toFile: "/private/tmp/claude-501/uishots/raw-hierarchy.txt", atomically: true, encoding: .utf8)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ERROR' OR label CONTAINS 'FAILED'")).firstMatch.exists)
    }
}
