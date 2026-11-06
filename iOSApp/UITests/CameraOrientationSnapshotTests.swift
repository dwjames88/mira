import XCTest

/// Portrait and landscape screenshots of the camera (simctl cannot rotate a headless simulator; XCUIDevice can).
/// Runs only when MIRA_SNAPSHOT_OUT names a directory (pass it as TEST_RUNNER_MIRA_SNAPSHOT_OUT to xcodebuild).
/// Simulator input only; nothing here touches the host.
@MainActor final class CameraOrientationSnapshotTests: XCTestCase {
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testCameraPortraitAndLandscape() throws {
        guard let out = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_OUT"], !out.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MIRA_SNAPSHOT_OUT to a directory to write the camera snapshots")
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MIRA_SNAPSHOT"] = "1"
        app.launchEnvironment["MIRA_SNAPSHOT_TAB"] = "camera"
        app.launch()
        sleep(4)
        try save("camera-portrait", to: dir)

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        try save("camera-landscape", to: dir)

        XCUIDevice.shared.orientation = .portrait
    }

    private func save(_ name: String, to dir: URL) throws {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
