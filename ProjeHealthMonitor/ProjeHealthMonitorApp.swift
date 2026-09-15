import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openSettings = Self("openSettings")
}

/// `openWindow` is a SwiftUI environment action — there's no way to obtain one from plain
/// AppKit/global-hotkey code that isn't part of the view hierarchy. `MenuBarIconView` is always
/// instantiated at launch (see its own doc comment) and already reads `openWindow`, so its `.task`
/// stashes it here once, giving `KeyboardShortcuts.onKeyUp` (registered before any view exists) a
/// way to call it later.
@MainActor
enum HotkeyBridge {
    static var openWindow: OpenWindowAction?
}

@MainActor
func presentSettingsWindow(using openWindow: OpenWindowAction) {
    // Defer until the current menu-bar button action finishes so the popover can dismiss cleanly
    // before we try to activate the app and focus the settings window.
    DispatchQueue.main.async {
        openWindow(id: "settings")
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if let settingsWindow = NSApp.windows.first(where: { $0.title == "Settings" }) {
            settingsWindow.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct ProjeHealthMonitorApp: App {
    @StateObject private var endpointStore: EndpointStore
    @StateObject private var historyStore: HealthHistoryStore
    @StateObject private var dailyStatsStore: DailyStatsStore
    @StateObject private var healthCheckService: HealthCheckService
    @StateObject private var updaterViewModel: UpdaterViewModel

    init() {
        let endpointStore: EndpointStore
        let historyStore: HealthHistoryStore
        let dailyStatsStore: DailyStatsStore
        if let isolatedStores = Self.makeIsolatedStoresForUITesting() {
            (endpointStore, historyStore, dailyStatsStore) = isolatedStores
        } else {
            endpointStore = EndpointStore()
            historyStore = HealthHistoryStore()
            dailyStatsStore = DailyStatsStore()
        }
        let notificationService = NotificationService()
        let healthCheckService = HealthCheckService(
            endpointStore: endpointStore,
            historyStore: historyStore,
            dailyStatsStore: dailyStatsStore,
            notificationService: notificationService
        )

        _endpointStore = StateObject(wrappedValue: endpointStore)
        _historyStore = StateObject(wrappedValue: historyStore)
        _dailyStatsStore = StateObject(wrappedValue: dailyStatsStore)
        _healthCheckService = StateObject(wrappedValue: healthCheckService)
        _updaterViewModel = StateObject(wrappedValue: UpdaterViewModel())

        notificationService.requestAuthorizationIfNeeded()
        healthCheckService.start()

        // Toggling the MenuBarExtra popover itself from a global hotkey isn't possible with
        // public API (open SwiftUI limitation, FB10185203) — this opens Settings instead, via
        // the same presentSettingsWindow(using:) the popover's own buttons and onboarding use.
        KeyboardShortcuts.onKeyUp(for: .openSettings) {
            guard let openWindow = HotkeyBridge.openWindow else { return }
            presentSettingsWindow(using: openWindow)
        }
    }

    /// UI tests pass `-UITestMode` so each run gets its own throwaway `UserDefaults` suite and
    /// history/stats files, rather than reading and writing the real installed app's data.
    private static func makeIsolatedStoresForUITesting() -> (EndpointStore, HealthHistoryStore, DailyStatsStore)? {
        guard ProcessInfo.processInfo.arguments.contains("-UITestMode") else { return nil }
        let runID = UUID().uuidString
        let defaults = UserDefaults(suiteName: "UITests.\(runID)") ?? .standard
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("UITests-\(runID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        return (
            EndpointStore(defaults: defaults),
            HealthHistoryStore(fileURL: tempDirectory.appendingPathComponent("history.json")),
            DailyStatsStore(fileURL: tempDirectory.appendingPathComponent("dailyStats.json"))
        )
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(endpointStore)
                .environmentObject(historyStore)
        } label: {
            MenuBarIconView(status: healthCheckService.overallStatus)
                .environmentObject(endpointStore)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(endpointStore)
                .environmentObject(historyStore)
                .environmentObject(dailyStatsStore)
                .environmentObject(updaterViewModel)
        }
        .windowResizability(.contentSize)
    }
}
