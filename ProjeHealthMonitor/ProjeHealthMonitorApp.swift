import SwiftUI

@main
struct ProjeHealthMonitorApp: App {
    @StateObject private var endpointStore: EndpointStore
    @StateObject private var historyStore: HealthHistoryStore
    @StateObject private var dailyStatsStore: DailyStatsStore
    @StateObject private var healthCheckService: HealthCheckService
    @StateObject private var updaterViewModel: UpdaterViewModel

    init() {
        let endpointStore = EndpointStore()
        let historyStore = HealthHistoryStore()
        let dailyStatsStore = DailyStatsStore()
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
                .environmentObject(dailyStatsStore)
                .environmentObject(updaterViewModel)
        }
        .windowResizability(.contentSize)
    }
}
