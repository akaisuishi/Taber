import XCTest

final class TaberUITests: XCTestCase {
    @MainActor
    func testSettingsSidebarAndStandardWindowShortcuts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.windows["Taber"].waitForExistence(timeout: 10))
        for section in ["appearance", "behavior", "shortcuts", "permissions"] {
            let button = app.buttons["settings.section.\(section)"]
            XCTAssertTrue(button.exists); button.click()
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows["Taber"].exists)
        XCTAssertEqual(app.state, .runningForeground)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Taber"].waitForExistence(timeout: 3))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }
}
