import XCTest

/// The UI tests need a prepared simulator (Photos granted, media seeded). Without it they skip, not fail.
enum Preconditions {
    static let hint = "Simulator not prepared (Photos access / seeded library): run scripts/ios-uitests.sh"

    /// Launches the app and skips quickly when the album list never appears (no Photos access).
    @MainActor static func launchOrSkip(_ app: XCUIApplication) throws {
        app.launch()
        if !app.staticTexts["Library"].waitForExistence(timeout: 8) {
            throw XCTSkip(hint)
        }
    }
}
