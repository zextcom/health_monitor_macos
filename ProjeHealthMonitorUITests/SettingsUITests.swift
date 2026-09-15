import XCTest

@MainActor
final class SettingsUITests: UITestCase {
    func testSettingsWindowOpensOnGeneralTabByDefault() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = Self.openSettingsWindow(in: app)
        XCTAssertTrue(settingsWindow.staticTexts["Check Frequency"].waitForExistence(timeout: 5))
    }

    func testAboutTabShowsAppName() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("About", in: settingsWindow, app: app)
        XCTAssertTrue(settingsWindow.staticTexts["Health Mntr"].waitForExistence(timeout: 5))
    }

    func testEndpointsTabShowsEmptyStateOnFreshLaunch() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("Endpoints", in: settingsWindow, app: app)
        XCTAssertTrue(settingsWindow.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(settingsWindow.buttons["Add Endpoint"].exists)
    }

    func testUpdatesTabShowsCheckForUpdatesButton() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("Updates", in: settingsWindow, app: app)
        XCTAssertTrue(settingsWindow.buttons["Check for Updates Now"].waitForExistence(timeout: 5))
    }

    func testStatsTabShowsEmptyStateOnFreshLaunch() {
        let app = Self.launchApp()
        defer { app.terminate() }
        let settingsWindow = Self.openSettingsWindow(in: app)
        Self.selectSettingsTab("Stats", in: settingsWindow, app: app)
        XCTAssertTrue(settingsWindow.staticTexts["No endpoints added yet"].waitForExistence(timeout: 5))
    }
}
