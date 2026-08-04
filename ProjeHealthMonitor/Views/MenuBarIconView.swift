import SwiftUI

struct MenuBarIconView: View {
    let status: HealthCheckService.OverallStatus

    var body: some View {
        Image(systemName: "circle.fill")
            .renderingMode(.original)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .healthy: return .green
        case .down: return .red
        case .unknown: return .gray
        }
    }
}
