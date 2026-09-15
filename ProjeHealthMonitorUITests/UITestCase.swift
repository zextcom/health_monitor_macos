import XCTest

/// Base class for UI tests: launches the app with `-UITestMode` so it uses a throwaway
/// `UserDefaults` suite and scratch history/stats files instead of the real installed app's data
/// (see `ProjeHealthMonitorApp.makeIsolatedStoresForUITesting`).
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        Self.clearSavedWindowState()
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
    }

    /// macOS restores window state (e.g. a still-open Settings window) across launches of the
    /// same bundle identifier. Clearing it keeps every test starting from the same clean
    /// menu-bar-only state regardless of how the previous run ended.
    private static func clearSavedWindowState() {
        let savedStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.zext.healthmonitor.savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        try super.tearDownWithError()
    }

    /// The app has exactly one `NSStatusItem` (`MenuBarIconView`'s icon), so the first match is
    /// unambiguous — its accessibility label isn't reliably queryable by prefix through the
    /// status-item element itself.
    @discardableResult
    func openPopover() -> XCUIElement {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Menu bar status item never appeared")

        // A crowded menu bar (many other apps' status items competing for space) can make the
        // click land slightly off-target or fail hittability, so click by coordinate and retry a
        // few times rather than relying on a single `.click()` succeeding.
        for attempt in 1...3 {
            statusItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            if app.buttons["Settings"].waitForExistence(timeout: 2) || app.buttons["Add in Settings"].waitForExistence(timeout: 1) {
                break
            } else if attempt == 3 {
                XCTFail("Popover never opened after 3 attempts to click the menu bar status item")
            }
        }
        return statusItem
    }

    @discardableResult
    func openSettingsWindow() -> XCUIElement {
        openPopover()
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button never appeared in the popover")
        settingsButton.click()

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window never appeared")
        return settingsWindow
    }

    /// At the Settings window's fixed 480pt width, macOS collapses the `TabView`'s toolbar tabs
    /// behind a "more toolbar items" popup button (itself nested one level under a "Navigation
    /// Tab Bar" menu item) rather than showing them individually — so switching tabs always goes
    /// through this menu, never a directly-clickable tab button.
    func selectSettingsTab(_ title: String, in settingsWindow: XCUIElement) {
        let moreButton = settingsWindow.popUpButtons["more toolbar items"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5), "\"more toolbar items\" popup never appeared")
        moreButton.click()

        let navigationTabBar = app.menuItems["Navigation Tab Bar"]
        XCTAssertTrue(navigationTabBar.waitForExistence(timeout: 5), "Navigation Tab Bar submenu never appeared")
        navigationTabBar.click()

        let tabMenuItem = app.menuItems[title]
        XCTAssertTrue(tabMenuItem.waitForExistence(timeout: 5), "\(title) menu item never appeared")
        tabMenuItem.click()
    }
}
