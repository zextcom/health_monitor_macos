import SwiftUI

/// Shared look of the healthy/degraded/down indicator. Shape differs per state, not just color, so
/// it reads correctly for color-blind users: check (healthy), triangle (degraded), circle with
/// exclamation mark (down).
extension EndpointHealthState {
    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .down: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }

    var label: String {
        switch self {
        case .healthy: return "healthy"
        case .degraded: return "degraded"
        case .down: return "down"
        }
    }
}

extension HealthStandardStatus {
    var symbolName: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}
