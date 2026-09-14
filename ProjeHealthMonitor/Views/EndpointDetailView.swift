import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// Per-endpoint detail sheet, reached by tapping a row in Settings' Stats tab — response time
/// trend, derived incident history, and raw history export. Kept as a separate sheet rather than
/// inline in the Stats list so that list stays scannable with many endpoints.
struct EndpointDetailView: View {
    let endpoint: Endpoint

    @EnvironmentObject var historyStore: HealthHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    private var results: [HealthCheckResult] { historyStore.results(for: endpoint.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    responseTimeSection
                    incidentSection
                    exportSection
                }
                .padding()
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 600)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name).font(.title3.bold())
                Text(endpoint.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Response time chart

    private var chartableResults: [HealthCheckResult] {
        results.filter { $0.responseTimeMs != nil }
    }

    @ViewBuilder
    private var responseTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Response Time").font(.headline)
            if chartableResults.isEmpty {
                Text("No response time data yet").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(chartableResults) { result in
                    LineMark(
                        x: .value("Time", result.timestamp),
                        y: .value("Response time (ms)", result.responseTimeMs ?? 0)
                    )
                    .foregroundStyle(.secondary)
                    PointMark(
                        x: .value("Time", result.timestamp),
                        y: .value("Response time (ms)", result.responseTimeMs ?? 0)
                    )
                    .foregroundStyle(result.isHealthy ? Color.green : Color.red)
                }
                .frame(height: 160)
                .accessibilityLabel(responseTimeSummary)
            }
        }
    }

    private var responseTimeSummary: String {
        let values = chartableResults.compactMap(\.responseTimeMs)
        guard let minValue = values.min(), let maxValue = values.max(), !values.isEmpty else {
            return "No response time data"
        }
        let average = values.reduce(0, +) / values.count
        return "Response time over \(values.count) checks: minimum \(minValue) ms, average \(average) ms, maximum \(maxValue) ms"
    }

    // MARK: - Incidents

    /// Most recent first, capped — older incidents are still in the exported history, just not
    /// listed here.
    private var incidents: [Incident] {
        Array(HealthCheckService.incidents(from: results).reversed().prefix(20))
    }

    @ViewBuilder
    private var incidentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incidents").font(.headline)
            if incidents.isEmpty {
                Text("No incidents in the retained history").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(incidents) { incident in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incidentRangeText(incident)).font(.caption)
                            if let reason = incident.failureReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func incidentRangeText(_ incident: Incident) -> String {
        guard let endedAt = incident.endedAt else {
            let prefix = incident.startBoundaryUncertain ? "Down since before recorded history, at least since " : "Since "
            return "\(prefix)\(Self.dateTimeFormatter.string(from: incident.startedAt)) (ongoing)"
        }
        let duration = Self.durationFormatter.string(from: endedAt.timeIntervalSince(incident.startedAt)) ?? "0m"
        let endText = "\(Self.timeOnlyFormatter.string(from: endedAt)) (\(duration))"
        if incident.startBoundaryUncertain {
            return "…\(endText) — started before recorded history"
        }
        return "\(Self.dateTimeFormatter.string(from: incident.startedAt)) – \(endText)"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export History").font(.headline)
            HStack {
                Button("Export as JSON") { exportJSON() }
                Button("Export as CSV") { exportCSV() }
            }
            .disabled(results.isEmpty)
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var sanitizedFileNamePrefix: String {
        let allowed = endpoint.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(allowed)
    }

    private func exportJSON() {
        guard let data = try? JSONEncoder().encode(results) else {
            exportError = "Couldn't prepare history for export"
            return
        }
        saveToFile(data: data, suggestedName: "\(sanitizedFileNamePrefix)-history.json", type: .json)
    }

    private func exportCSV() {
        let csv = HealthCheckService.csv(for: results, endpointName: endpoint.name)
        saveToFile(data: Data(csv.utf8), suggestedName: "\(sanitizedFileNamePrefix)-history.csv", type: .commaSeparatedText)
    }

    private func saveToFile(data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            exportError = nil
        } catch {
            exportError = "Couldn't save file: \(error.localizedDescription)"
        }
    }
}
