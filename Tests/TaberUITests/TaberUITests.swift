import XCTest

final class LiveHIDIntegrationTests: XCTestCase {
    /// Optional live test: never creates, navigates or closes personal tabs.
    @MainActor
    func testLiveChromeFixtureSwitching() throws {
        let chrome = XCUIApplication(bundleIdentifier: "com.google.Chrome")
        guard chrome.state != .notRunning else { throw XCTSkip("Chrome fixture windows are not open") }
        let a = chrome.windows.matching(NSPredicate(format: "title CONTAINS %@", "Taber Fixture A"))
        let b = chrome.windows.matching(NSPredicate(format: "title CONTAINS %@", "Taber Fixture B"))
        guard a.count == 1, b.count == 1 else { throw XCTSkip("Requires disposable Taber Fixture A/B windows and installed Taber") }
        chrome.activate()
        let original = chrome.windows.firstMatch.title
        guard original.contains("Taber Fixture") else { throw XCTSkip("A personal window is focused; not interacting") }
        chrome.typeKey(.tab, modifierFlags: .command)
        let changed = NSPredicate { _, _ in chrome.windows.firstMatch.title != original }
        let changedExpectation = XCTNSPredicateExpectation(predicate: changed, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changedExpectation], timeout: 3), .completed)
        XCTAssertTrue(chrome.windows.firstMatch.title.contains("Taber Fixture"))
        chrome.typeKey(.tab, modifierFlags: .command)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in chrome.windows.firstMatch.title == original }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 3), .completed)
    }
}

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
        app.buttons["settings.section.appearance"].click()
        let transparency = app.descendants(matching: .any)
            .matching(identifier: "appearance.transparency").firstMatch
        XCTAssertTrue(transparency.waitForExistence(timeout: 2))
        XCTAssertTrue(transparency.isHittable)
        transparency.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows["Taber"].exists)
        XCTAssertEqual(app.state, .runningForeground)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Taber"].waitForExistence(timeout: 3))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 3))
    }
}
