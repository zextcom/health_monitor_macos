import XCTest

@MainActor
final class VersionCheckUITests: UITestCase {
    private static let testURL = "https://example.invalid/health"
    private static let versionURL = "https://example.invalid/version"

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

    /// The "Advanced" DisclosureGroup sits at the bottom of a scrolling Form and is exposed
    /// (chevron plus label) as a disclosure triangle labelled "Advanced". Click it once only — a
    /// second click would collapse it again.
    private func expandAdvanced(in window: XCUIElement) {
        let toggle = window.descendants(matching: .any)["VersionCheckToggle"]
        if toggle.exists { return }
        let triangle = window.disclosureTriangles["Advanced"]
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "Advanced disclosure never appeared")
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1000)
        triangle.click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Version check toggle never appeared after expanding Advanced")
    }

    /// The version fields render below the Form's visible area; scroll to the bottom before
    /// clicking, otherwise the click lands outside the viewport and never focuses the field.
    private func type(_ text: String, into identifier: String, in window: XCUIElement, replacing: Bool = false) {
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1000)
        let field = window.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(identifier) never appeared")
        if replacing {
            field.doubleClick()
        } else {
            field.click()
        }
        field.typeText(text)
    }

    private func enableVersionCheck(in window: XCUIElement) {
        let toggle = window.descendants(matching: .any)["VersionCheckToggle"]
        toggle.click()
        XCTAssertTrue(window.textFields["VersionURLField"].waitForExistence(timeout: 5), "Version fields never appeared")
    }

    func testEnablingVersionCheckWithoutURLShowsValidationError() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let window = openAddEndpointForm(in: app)
        fillBasics(in: window, name: "UITest-Version-\(UUID().uuidString.prefix(8))")

        expandAdvanced(in: window)
        enableVersionCheck(in: window)
        window.buttons["Save"].click()

        XCTAssertTrue(window.staticTexts["Enter a valid http(s) URL for the version check"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Add Endpoint"].exists, "Sheet must stay open after a rejected save")
    }

    func testVersionCheckConfigIsSavedAndRestoredOnEdit() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let window = openAddEndpointForm(in: app)
        let name = "UITest-Version-\(UUID().uuidString.prefix(8))"
        fillBasics(in: window, name: name)

        expandAdvanced(in: window)
        enableVersionCheck(in: window)
        type(Self.versionURL, into: "VersionURLField", in: window)
        type("3", into: "VersionEveryNField", in: window, replacing: true)
        type("data.version", into: "VersionFieldPathField", in: window)
        window.buttons["Save"].click()

        XCTAssertTrue(window.staticTexts[name].waitForExistence(timeout: 5), "Saved endpoint never appeared in the list")

        // Re-open in edit mode: Advanced is pre-expanded for an enabled version check, with values restored.
        window.buttons["Edit"].firstMatch.click()
        XCTAssertTrue(window.staticTexts["Edit Endpoint"].waitForExistence(timeout: 5))
        let urlField = window.textFields["VersionURLField"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Advanced panel should open automatically when a version check is enabled")
        XCTAssertEqual(urlField.value as? String, Self.versionURL)
        XCTAssertEqual(window.textFields["VersionEveryNField"].value as? String, "3")
        XCTAssertEqual(window.textFields["VersionFieldPathField"].value as? String, "data.version")
    }
}
