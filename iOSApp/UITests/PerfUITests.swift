import XCTest

/// Round 3 performance baselines of the real app in the simulator. Opt-in: `TEST_RUNNER_MIRA_PERF=1`, and
/// `TEST_RUNNER_MIRA_PERF_OUT=<dir>` for the phase markers. Simulator input only. The prepared simulator of
/// scripts/ios-uitests.sh is needed for the library tests (Photos granted, media seeded).
///
///   - launch: `XCTApplicationLaunchMetric` (launch to first frame) plus `XCTMemoryMetric` of the app
///   - gallery: time from the tap on the Library row to the grid header and to the first image, then scroll
///     (`XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTHitchMetric`, CPU, memory)
///   - editor round trip: the thumbnail request counter must not move after the editor closes; the runner writes phase
///     markers (`PHASE <name> <epoch>`) to `phases.txt`, and a `log stream` on the `thumbs` category (see
///     build/round3/tools/perf-ios-ui.sh) holds the app's `requested=N` counter to compare across them
///   - camera stats: `MIRA_CAMERA_STATS=1` finder readout from Camera settings (the fake source, so a proxy)
@MainActor final class PerfUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_PERF"] == "1", "set TEST_RUNNER_MIRA_PERF=1")
        XCUIDevice.shared.orientation = .portrait
    }

    private func phase(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MIRA_PERF_OUT"] else { return }
        let line = "PHASE \(name) \(Date().timeIntervalSince1970)\n"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("phases.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        print("PERFPHASE \(line)", terminator: "")
    }

    private func openGrid(_ app: XCUIApplication) throws {
        try Preconditions.openLibraryFromCamera(app)
        guard app.staticTexts["Library"].waitForExistence(timeout: 20) else { throw XCTSkip(Preconditions.hint) }
        app.staticTexts["Library"].tap()
        _ = app.buttons["ALL"].waitForExistence(timeout: 20)
    }

    // MARK: Launch

    func testColdLaunch() {
        let app = XCUIApplication()
        let options = XCTMeasureOptions(); options.iterationCount = 7
        measure(metrics: [XCTApplicationLaunchMetric(), XCTMemoryMetric(application: app)], options: options) {
            app.launch()
            _ = app.buttons["camera.library"].waitForExistence(timeout: 20)
            app.terminate()
        }
    }

    // MARK: Gallery

    func testGalleryFirstPaint() throws {
        let app = XCUIApplication()
        app.launch()
        try Preconditions.openLibraryFromCamera(app)
        guard app.staticTexts["Library"].waitForExistence(timeout: 20) else { throw XCTSkip(Preconditions.hint) }
        var header: [Double] = [], image: [Double] = []
        for i in 0..<5 {
            if i > 0 { app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(2) }
            let t0 = Date()
            app.staticTexts["Library"].tap()
            if app.buttons["ALL"].waitForExistence(timeout: 20) { header.append(Date().timeIntervalSince(t0) * 1000) }
            if app.images.firstMatch.waitForExistence(timeout: 20) { image.append(Date().timeIntervalSince(t0) * 1000) }
        }
        print("PERFRESULT gallery grid header (tap -> ALL tab exists) ms: \(header.map { Int($0) })")
        print("PERFRESULT gallery first image (tap -> first image exists) ms: \(image.map { Int($0) })")
    }

    func testGalleryScroll() throws {
        let app = XCUIApplication()
        app.launch()
        try openGrid(app)
        sleep(4)
        let scroll = app.scrollViews.firstMatch
        let options = XCTMeasureOptions(); options.iterationCount = 5
        var metrics: [XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                                    XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics, options: options) {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeUp(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
        }
    }

    func testEditorRoundTripAndThumbnailRequests() throws {
        let app = XCUIApplication()
        app.launch()
        try openGrid(app)
        sleep(6)
        phase("grid-settled")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.2)).tap()
        phase("editor-tapped")
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 60), "editor never opened")
        sleep(10)
        phase("editor-open-settled")
        app.buttons["Back to library"].tap()
        phase("editor-closed")
        sleep(8)
        phase("after-close-8s")
    }

    // MARK: Camera stats

    func testCameraFinderStats() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MIRA_CAMERA_STATS"] = "1"
        app.launch()
        guard app.buttons["camera.library"].waitForExistence(timeout: 20) else { throw XCTSkip("no camera screen") }
        sleep(15)   // the stats window fills over a few seconds of frames
        app.buttons["Camera settings"].tap()
        let stats = app.staticTexts["Finder statistics"]
        if stats.waitForExistence(timeout: 10) {
            print("PERFRESULT camera finder statistics: \(stats.label) | value: \(String(describing: stats.value))")
        } else {
            print("PERFRESULT camera finder statistics: not shown (fake source in the simulator reports none)")
        }
    }
}
