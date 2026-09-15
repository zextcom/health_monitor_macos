import XCTest

final class PopoverUITests: UITestCase {
    func testMenuBarIconOpensPopoverWithSettingsAndQuit() {
        openPopover()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Quit"].waitForExistence(timeout: 5))
    }

    func testEmptyStateShowsAddInSettingsPrompt() {
        // Fresh `-UITestMode` launch has no endpoints yet, so the popover shows the empty state.
        openPopover()
        XCTAssertTrue(app.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add in Settings"].exists)
    }

    func testAddInSettingsOpensSettingsWindow() {
        openPopover()
        app.buttons["Add in Settings"].click()
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    }
}
