import XCTest

@MainActor
final class PopoverUITests: UITestCase {
    func testMenuBarIconOpensPopoverWithSettingsAndQuit() {
        let app = Self.launchApp()
        defer { app.terminate() }
        Self.openPopover(in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Quit"].waitForExistence(timeout: 5))
    }

    func testEmptyStateShowsAddInSettingsPrompt() {
        let app = Self.launchApp()
        defer { app.terminate() }
        // Fresh `-UITestMode` launch has no endpoints yet, so the popover shows the empty state.
        Self.openPopover(in: app)
        XCTAssertTrue(app.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add in Settings"].exists)
    }

    func testAddInSettingsOpensSettingsWindow() {
        let app = Self.launchApp()
        defer { app.terminate() }
        Self.openPopover(in: app)
        app.buttons["Add in Settings"].click()
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    }
}
