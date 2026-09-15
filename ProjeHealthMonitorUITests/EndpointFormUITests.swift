import XCTest

@MainActor
final class EndpointFormUITests: UITestCase {
    /// `.invalid` is an IANA-reserved TLD guaranteed to never resolve — safe to use as a health
    /// check target in a UI test without making a real network request succeed or fail flakily.
    private static let testURL = "https://example.invalid/health"

    private func openAddEndpointForm(in app: XCUIApplication) -> XCUIElement {
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("Endpoints", in: settingsWindow, app: app)
        settingsWindow.buttons["Add Endpoint"].click()
        let sheetTitle = settingsWindow.staticTexts["Add Endpoint"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Add Endpoint sheet never appeared")
        return settingsWindow
    }

    func testAddEndpointWithNameAndURLAddsItToTheList() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = openAddEndpointForm(in: app)
        let name = "UITest-\(UUID().uuidString.prefix(8))"

        settingsWindow.textFields["EndpointNameField"].click()
        settingsWindow.textFields["EndpointNameField"].typeText(name)
        settingsWindow.textFields["EndpointURLField"].click()
        settingsWindow.textFields["EndpointURLField"].typeText(Self.testURL)
        settingsWindow.buttons["Save"].click()

        XCTAssertTrue(settingsWindow.staticTexts[name].waitForExistence(timeout: 5),
                      "Newly added endpoint never appeared in the Endpoints list")
    }

    func testSaveWithEmptyNameShowsValidationErrorAndDoesNotClose() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = openAddEndpointForm(in: app)
        settingsWindow.textFields["EndpointURLField"].click()
        settingsWindow.textFields["EndpointURLField"].typeText(Self.testURL)
        settingsWindow.buttons["Save"].click()

        XCTAssertTrue(settingsWindow.staticTexts["Name cannot be empty"].waitForExistence(timeout: 5))
        // The sheet must still be open — the invalid save was rejected, not silently dropped.
        XCTAssertTrue(settingsWindow.staticTexts["Add Endpoint"].exists)
    }

    func testCancelDiscardsEnteredDataAndReturnsToEmptyState() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = openAddEndpointForm(in: app)
        let name = "UITest-Cancelled-\(UUID().uuidString.prefix(8))"
        settingsWindow.textFields["EndpointNameField"].click()
        settingsWindow.textFields["EndpointNameField"].typeText(name)
        settingsWindow.buttons["Cancel"].click()

        XCTAssertTrue(settingsWindow.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(settingsWindow.staticTexts[name].exists)
    }
}
