import SwiftUI

struct MenuBarIconView: View {
    let status: HealthCheckService.OverallStatus

    var body: some View {
        Image(systemName: symbolName)
            .renderingMode(.original)
            .foregroundStyle(color)
            .accessibilityLabel("Health status: \(accessibilityDescription)")
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
