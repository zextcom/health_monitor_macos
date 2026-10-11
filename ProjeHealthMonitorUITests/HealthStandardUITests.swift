import XCTest

@MainActor
final class HealthStandardUITests: UITestCase {
    private static let testURL = "https://example.invalid/health"

    private func openAddEndpointForm(in app: XCUIApplication) -> XCUIElement {
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("Endpoints", in: settingsWindow, app: app)
        settingsWindow.buttons["Add Endpoint"].click()
        XCTAssertTrue(settingsWindow.staticTexts["Add Endpoint"].waitForExistence(timeout: 5), "Add Endpoint sheet never appeared")
        return settingsWindow
    }

    private func fillBasics(in window: XCUIElement, name: String) {
        window.textFields["EndpointNameField"].click()
        window.textFields["EndpointNameField"].typeText(name)
        window.textFields["EndpointURLField"].click()
        window.textFields["EndpointURLField"].typeText(Self.testURL)
    }

    /// Toggles render as a switch or checkbox depending on macOS version; both expose 0/1.
    private func isOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber { return number.boolValue }
        if let string = element.value as? String { return string == "1" || string.lowercased() == "on" }
        return false
    }

    func testToggleHidesStatusCodeAndIsSavedAndRestored() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let window = openAddEndpointForm(in: app)
        let name = "UITest-Standard-\(UUID().uuidString.prefix(8))"
        fillBasics(in: window, name: name)

        let toggle = window.descendants(matching: .any)["HealthStandardToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Health standard toggle never appeared")
        XCTAssertFalse(isOn(toggle))
        XCTAssertTrue(window.textFields["ExpectedStatusCodeField"].exists, "Status code field should show while the toggle is off")

        toggle.click()
        XCTAssertTrue(isOn(toggle), "Toggle should be on after clicking it")
        let statusField = window.textFields["ExpectedStatusCodeField"]
        let hidden = NSPredicate(format: "exists == false")
        expectation(for: hidden, evaluatedWith: statusField)
        waitForExpectations(timeout: 5)

        window.buttons["Save"].click()
        XCTAssertTrue(window.staticTexts[name].waitForExistence(timeout: 5), "Saved endpoint never appeared in the list")

        // Re-open in edit mode: the toggle is restored and the status code field stays hidden.
        window.buttons["Edit"].firstMatch.click()
        XCTAssertTrue(window.staticTexts["Edit Endpoint"].waitForExistence(timeout: 5))
        let editToggle = window.descendants(matching: .any)["HealthStandardToggle"]
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(isOn(editToggle), "Health standard should be restored as on")
        XCTAssertFalse(window.textFields["ExpectedStatusCodeField"].exists, "Status code field should stay hidden")
    }
}
