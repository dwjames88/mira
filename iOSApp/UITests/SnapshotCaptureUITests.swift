import XCTest

/// Round 3 "before/after" screenshots of the real app in the simulator. Runs only when MIRA_SNAPSHOT_OUT names a
/// directory (pass it as TEST_RUNNER_MIRA_SNAPSHOT_OUT); needs the prepared simulator of scripts/ios-uitests.sh
/// (Photos granted, media seeded). Simulator input only; nothing touches the host. Pair it with
/// `xcrun simctl status_bar <udid> override --time 9:41 ...` so the clock does not differ between runs.
///
/// Two kinds of shot, kept apart on purpose:
///   - `ui-*.png`: screens that do not depend on the simulator's Photos library: the camera (fake frame source), its
///     film door and settings, the DEVELOP queue (empty on a fresh install), and the four editor steps on the built-in
///     fixture photo (MIRA_SNAPSHOT=1 launch, then the step bar is tapped). These belong to the zero-diff set.
///   - `library/lib-*.png`: the album list, a grid, RAW filter and SELECT mode of the real library. Their content is
///     whatever the shared simulator holds (other test runs add and edit assets), so they only show layout; do not
///     diff them pixel for pixel.
/// A missing control only skips its shot (logged), so one UI change does not hide the rest.
@MainActor final class SnapshotCaptureUITests: XCTestCase {
    private var dir: URL!
    private var libraryDir: URL!
    private var missing: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let out = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_OUT"], !out.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MIRA_SNAPSHOT_OUT to a directory to write the UI snapshots")
        }
        dir = URL(fileURLWithPath: out, isDirectory: true)
        libraryDir = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        if !missing.isEmpty { print("SNAPSHOT-MISSING \(missing)") }
    }

    private func shot(_ name: String, in folder: URL? = nil, settle: UInt32 = 3) {
        sleep(settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: (folder ?? dir).appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps `element` if it shows up within `timeout`; otherwise records it and returns false.
    @discardableResult
    private func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { missing.append(what); return false }
        element.tap()
        return true
    }

    private func back(_ app: XCUIApplication) {
        let bar = app.navigationBars.buttons.element(boundBy: 0)
        if bar.waitForExistence(timeout: 5) { bar.tap() } else { missing.append("navigation back") }
        sleep(1)
    }

    // MARK: Camera, DEVELOP queue, library layouts

    func testCameraDevelopQueueAndLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        guard app.buttons["camera.library"].waitForExistence(timeout: 20) else { return XCTFail("camera never appeared") }
        shot("ui-camera", settle: 4)
        // The film button is labelled "Film: <name>".
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Film'")).firstMatch
        if tap(film, "camera film button", timeout: 5) {
            shot("ui-camera-film-door", settle: 3)
            film.tap()
            sleep(1)
        }
        if tap(app.buttons["Camera settings"], "camera settings button", timeout: 5) {
            shot("ui-camera-settings", settle: 2)
            app.swipeDown()   // dismiss the sheet by its drag indicator gesture
            sleep(1)
        }

        // The album list, the DEVELOP card and the (empty) queue.
        guard tap(app.buttons["camera.library"], "camera.library") else { return }
        guard app.staticTexts["Library"].waitForExistence(timeout: 20) else { return XCTFail("library never appeared (prepare the simulator with scripts/ios-uitests.sh)") }
        shot("lib-albums", in: libraryDir, settle: 5)
        if tap(app.descendants(matching: .any)["library.developCard"], "DEVELOP card", timeout: 10) {
            shot("ui-develop-queue", settle: 3)
            back(app)
        }

        // Album grid, RAW filter, SELECT mode (library content: layout only).
        guard tap(app.staticTexts["Library"], "Library row") else { return }
        _ = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'PHOTOS' OR label ENDSWITH ' RAW'")).firstMatch.waitForExistence(timeout: 20)
        shot("lib-grid", in: libraryDir, settle: 6)
        let rawTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'RAW'")).firstMatch
        if tap(rawTab, "RAW filter tab", timeout: 5) {
            shot("lib-grid-raw", in: libraryDir, settle: 4)
            app.buttons["ALL"].tap()
            sleep(2)
        }
        if tap(app.buttons["library.select"], "SELECT button", timeout: 5) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.2)).tap()
            shot("lib-grid-select", in: libraryDir, settle: 2)
            app.buttons["library.select"].tap()
        }
    }

    // MARK: Editor steps on the fixture photo

    func testEditorStepsOnFixture() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MIRA_SNAPSHOT"] = "1"
        app.launchEnvironment["MIRA_SNAPSHOT_TAB"] = "films"
        app.launch()
        guard app.buttons["Crop"].waitForExistence(timeout: 30) else { return XCTFail("editor never appeared") }
        // The fixture loads, the preview renders and the film thumbnails fill the strip.
        shot("ui-editor-films", settle: 12)
        for (title, name) in [("Crop", "ui-editor-crop"), ("Develop", "ui-editor-develop"), ("Dodge & Burn", "ui-editor-dodgeburn")] {
            if tap(app.buttons[title], "step \(title)", timeout: 5) { shot(name, settle: 4) }
        }
        tap(app.buttons["Films"], "step Films", timeout: 5)
        sleep(2)
        let hide = app.buttons["Hide controls"]
        if hide.waitForExistence(timeout: 3) {
            hide.tap()
            shot("ui-editor-films-hidden", settle: 3)
        }
    }
}
