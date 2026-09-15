import XCTest

final class SettingsUITests: UITestCase {
    func testSettingsWindowOpensOnGeneralTabByDefault() {
        let settingsWindow = openSettingsWindow()
        XCTAssertTrue(settingsWindow.staticTexts["Check Frequency"].waitForExistence(timeout: 5))
    }

    func testAboutTabShowsAppName() {
        let settingsWindow = openSettingsWindow()
        selectSettingsTab("About", in: settingsWindow)
        XCTAssertTrue(settingsWindow.staticTexts["Health Mntr"].waitForExistence(timeout: 5))
    }

    func testEndpointsTabShowsEmptyStateOnFreshLaunch() {
        let settingsWindow = openSettingsWindow()
        selectSettingsTab("Endpoints", in: settingsWindow)
        XCTAssertTrue(settingsWindow.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(settingsWindow.buttons["Add Endpoint"].exists)
    }

    func testUpdatesTabShowsCheckForUpdatesButton() {
        let settingsWindow = openSettingsWindow()
        selectSettingsTab("Updates", in: settingsWindow)
        XCTAssertTrue(settingsWindow.buttons["Check for Updates Now"].waitForExistence(timeout: 5))
    }

    func testStatsTabShowsEmptyStateOnFreshLaunch() {
        let settingsWindow = openSettingsWindow()
        selectSettingsTab("Stats", in: settingsWindow)
        XCTAssertTrue(settingsWindow.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
    }
}
