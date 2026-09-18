import SwiftUI
import AppKit

struct MenuBarIconView: View {
    let status: HealthCheckService.OverallStatus

    @EnvironmentObject private var endpointStore: EndpointStore
    @EnvironmentObject private var backendAuth: BackendAuthStore
    @EnvironmentObject private var backendSync: BackendSyncService
    @Environment(\.openWindow) private var openWindow

    private var effectiveStatus: HealthCheckService.OverallStatus {
        guard backendAuth.isConnected, let dashboard = backendSync.dashboardData else {
            return status
        }
        if dashboard.summary.totalEndpoints == 0 { return .unknown }
        return dashboard.summary.unhealthyEndpoints > 0 ? .down : .healthy
    }

    var body: some View {
        Image(systemName: symbolName)
            .renderingMode(.original)
            .foregroundStyle(color)
            .accessibilityLabel("Health status: \(accessibilityDescription)")
            .task {
                // Always instantiated at launch (the popover's content closure is lazy, built
                // only once the user opens it) — the reliable place to hand the global hotkey a
                // way to open Settings later (see HotkeyBridge).
                HotkeyBridge.openWindow = openWindow

                // This is also the reliable place to open Settings once for a brand-new install —
                // without it, a menu-bar-only (LSUIElement) app can be easy to lose track of after
                // a fresh download, with no Dock icon or window to notice.
                guard !endpointStore.hasCompletedOnboarding else { return }
                endpointStore.hasCompletedOnboarding = true
                presentSettingsWindow(using: openWindow)
            }
    }

    /// Shape differs per status, not just color, so the icon reads correctly for color-blind users.
    private var symbolName: String {
        switch effectiveStatus {
        case .healthy: return "checkmark.circle.fill"
        case .down: return "exclamationmark.circle.fill"
        case .unknown: return "circle.dotted"
        }
    }

    private var color: Color {
        switch effectiveStatus {
        case .healthy: return .green
        case .down: return .red
        case .unknown: return .gray
        }
    }

    private var accessibilityDescription: String {
        switch effectiveStatus {
        case .healthy: return "All endpoints healthy"
        case .down: return "One or more endpoints down"
        case .unknown: return "No data yet"
        }
    }
}
