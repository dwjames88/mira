import XCTest

/// The UI tests need a prepared simulator (Photos granted, media seeded). Without it they skip, not fail.
enum Preconditions {
    static let hint = "Simulator not prepared (Photos access / seeded library): run scripts/ios-uitests.sh"

    /// Launches the app (it opens to the camera), brings up the library from the camera, and skips quickly
    /// when the album list never appears (no Photos access).
    @MainActor static func launchOrSkip(_ app: XCUIApplication) throws {
        app.launch()
        try openLibraryFromCamera(app)
        if !app.staticTexts["Library"].waitForExistence(timeout: 8) {
            throw XCTSkip(hint)
        }
    }

    /// The app opens to the camera: tap its LIBRARY link to bring up the gallery.
    @MainActor static func openLibraryFromCamera(_ app: XCUIApplication) throws {
        let link = app.buttons["camera.library"]
        guard link.waitForExistence(timeout: 15) else { throw XCTSkip("Camera screen never appeared") }
        link.tap()
    }
}
