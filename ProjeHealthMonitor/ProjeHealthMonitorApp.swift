import SwiftUI

@main
struct ProjeHealthMonitorApp: App {
    @StateObject private var endpointStore: EndpointStore
    @StateObject private var historyStore: HealthHistoryStore
    @StateObject private var healthCheckService: HealthCheckService

    init() {
        let endpointStore = EndpointStore()
        let historyStore = HealthHistoryStore()
        let notificationService = NotificationService()
        let healthCheckService = HealthCheckService(
            endpointStore: endpointStore,
            historyStore: historyStore,
            notificationService: notificationService
        )

        _endpointStore = StateObject(wrappedValue: endpointStore)
        _historyStore = StateObject(wrappedValue: historyStore)
        _healthCheckService = StateObject(wrappedValue: healthCheckService)

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
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(endpointStore)
        }
        .windowResizability(.contentSize)
    }
}
