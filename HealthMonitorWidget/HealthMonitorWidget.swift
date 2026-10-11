import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct HealthEntry: TimelineEntry {
    let date: Date
    let dashboard: WidgetDashboard?

    var summary: WidgetSummary {
        WidgetSummary(endpoints: dashboard?.endpoints ?? [])
    }
}

// MARK: - Timeline Provider

struct HealthTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: .now, dashboard: Self.sampleDashboard)
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        if context.isPreview {
            completion(HealthEntry(date: .now, dashboard: Self.sampleDashboard))
        } else {
            completion(HealthEntry(date: .now, dashboard: loadDashboard()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        let dashboard = loadDashboard()
        let entry = HealthEntry(date: .now, dashboard: dashboard)
        let nextRefresh = Date().addingTimeInterval(300) // 5 minutes
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadDashboard() -> WidgetDashboard? {
        guard let defaults = UserDefaults(suiteName: WidgetDashboard.suiteName),
              let data = defaults.data(forKey: WidgetDashboard.userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetDashboard.self, from: data)
    }

    private static let sampleDashboard = WidgetDashboard(
        endpoints: [
            WidgetEndpointStatus(name: "API Server", url: "https://api.example.com/health", isHealthy: true, responseTimeMs: 42, lastCheckedAt: .now, group: nil),
            WidgetEndpointStatus(name: "Web App", url: "https://app.example.com", isHealthy: true, responseTimeMs: 128, lastCheckedAt: .now, group: nil),
        ],
        updatedAt: .now
    )
}

// MARK: - State color

extension WidgetHealthState {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: HealthEntry

    var body: some View {
        let summary = entry.summary
        VStack(spacing: 8) {
            Image(systemName: summary.total > 0 ? summary.overallState.symbolName : "circle.dotted")
                .font(.system(size: 32))
                .foregroundStyle(summary.total > 0 ? summary.overallState.color : .secondary)

            if summary.total > 0 {
                Text(summary.headline)
                    .font(.system(.headline, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Text("No Data")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: HealthEntry

    var body: some View {
        if let dashboard = entry.dashboard, !dashboard.endpoints.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(dashboard.endpoints.prefix(4).enumerated()), id: \.offset) { _, endpoint in
                    HStack(spacing: 6) {
                        Image(systemName: endpoint.state.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(endpoint.state.color)

                        Text(endpoint.name)
                            .font(.system(.body, design: .rounded))
                            .lineLimit(1)

                        Spacer()

                        if let ms = endpoint.responseTimeMs {
                            Text("\(ms) ms")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if dashboard.endpoints.count > 4 {
                    Text("+\(dashboard.endpoints.count - 4) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(4)
        } else {
            VStack {
                Text("No Endpoints")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Open Health Mntr to add endpoints")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Entry View (reads widget family from environment)

struct HealthMonitorEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    let entry: HealthEntry

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Definition

struct HealthMonitorWidget: Widget {
    let kind = "HealthMonitorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthTimelineProvider()) { entry in
            HealthMonitorEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Health Monitor")
        .description("Shows the health status of your monitored endpoints.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Entry Point

@main
struct HealthMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        HealthMonitorWidget()
    }
}

#Preview("Small - Healthy", as: .systemSmall) {
    HealthMonitorWidget()
} timeline: {
    HealthEntry(date: .now, dashboard: WidgetDashboard(
        endpoints: [
            WidgetEndpointStatus(name: "API", url: "https://api.example.com", isHealthy: true, responseTimeMs: 42, lastCheckedAt: .now, group: nil),
            WidgetEndpointStatus(name: "Web", url: "https://web.example.com", isHealthy: true, responseTimeMs: 100, lastCheckedAt: .now, group: nil),
        ],
        updatedAt: .now
    ))
}

#Preview("Medium - Mixed", as: .systemMedium) {
    HealthMonitorWidget()
} timeline: {
    HealthEntry(date: .now, dashboard: WidgetDashboard(
        endpoints: [
            WidgetEndpointStatus(name: "API Server", url: "https://api.example.com", isHealthy: true, responseTimeMs: 42, lastCheckedAt: .now, group: nil),
            WidgetEndpointStatus(name: "Database", url: "tcp://db.example.com:5432", isHealthy: false, responseTimeMs: nil, lastCheckedAt: .now, group: nil),
            WidgetEndpointStatus(name: "Logs", url: "https://logs.example.com/health", isHealthy: true, isDegraded: true, responseTimeMs: 310, lastCheckedAt: .now, group: nil),
        ],
        updatedAt: .now
    ))
}
