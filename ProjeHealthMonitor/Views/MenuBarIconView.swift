import SwiftUI
import AppKit

struct MenuBarIconView: View {
    let status: HealthCheckService.OverallStatus

    @EnvironmentObject private var endpointStore: EndpointStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbolName)
            .renderingMode(.original)
            .foregroundStyle(color)
            .accessibilityLabel("Health status: \(accessibilityDescription)")
            .task {
                // The label is the one part of MenuBarExtra that's always instantiated at launch
                // (the popover's content closure is lazy, built only once the user opens it), so
                // this is the reliable place to open Settings once for a brand-new install —
                // without it, a menu-bar-only (LSUIElement) app can be easy to lose track of after
                // a fresh download, with no Dock icon or window to notice.
                guard !endpointStore.hasCompletedOnboarding else { return }
                endpointStore.hasCompletedOnboarding = true
                presentSettingsWindow(using: openWindow)
            }
    }

    /// Shape differs per status, not just color, so the icon reads correctly for color-blind users.
    private var symbolName: String {
        switch status {
        case .healthy: return "checkmark.circle.fill"
        case .down: return "exclamationmark.circle.fill"
        case .unknown: return "circle.dotted"
        }
    }

    private var color: Color {
        switch status {
        case .healthy: return .green
        case .down: return .red
        case .unknown: return .gray
        }
    }

    private var accessibilityDescription: String {
        switch status {
        case .healthy: return "All endpoints healthy"
        case .down: return "One or more endpoints down"
        case .unknown: return "No data yet"
        }
    }
}
