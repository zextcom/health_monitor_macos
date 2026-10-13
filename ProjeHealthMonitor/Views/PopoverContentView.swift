import SwiftUI
import AppKit

struct PopoverContentView: View {
    @EnvironmentObject var endpointStore: EndpointStore
    @EnvironmentObject var historyStore: HealthHistoryStore
    @EnvironmentObject var versionStore: VersionStore
    @EnvironmentObject var backendAuth: BackendAuthStore
    @EnvironmentObject var backendSync: BackendSyncService
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if backendAuth.isConnected {
                backendContent
            } else if endpointStore.endpoints.isEmpty {
                VStack(spacing: 8) {
                    Text("No endpoints added yet")
                        .foregroundStyle(.secondary)
                    Button("Add in Settings") {
                        presentSettingsWindow(using: openWindow)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                searchField
                if filteredEndpoints.isEmpty {
                    Text("No matching endpoints")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    PopoverList {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedSections) { section in
                                if groupedSections.count > 1 {
                                    groupHeader(section.title)
                                }
                                ForEach(section.endpoints) { endpoint in
                                    EndpointRowView(endpoint: endpoint, results: historyStore.results(for: endpoint.id),
                                                    versionState: versionStore.state(for: endpoint.id))
                                    if !isLastRow(endpoint, in: section) {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }
                }
            }

            Divider()

            HStack {
                Button("Settings") { presentSettingsWindow(using: openWindow) }
                    .buttonStyle(.plain)
                Spacer()
                if backendAuth.isConnected {
                    if backendSync.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.trailing, 4)
                    }
                    Button {
                        Task { await backendSync.syncNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(backendSync.isSyncing)
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private var backendContent: some View {
        if let dashboard = backendSync.dashboardData {
            HStack(spacing: 12) {
                Label("\(dashboard.summary.healthyEndpoints)/\(dashboard.summary.totalEndpoints)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if dashboard.summary.unhealthyEndpoints > 0 {
                    Label("\(dashboard.summary.unhealthyEndpoints)", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(String(format: "%.1f%%", dashboard.summary.overallUptimePercent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            searchField

            PopoverList {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredBackendEndpoints) { endpoint in
                        BackendEndpointRowView(endpoint: endpoint)
                        if endpoint.id != filteredBackendEndpoints.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        } else if backendSync.isSyncing {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading dashboard…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            VStack(spacing: 8) {
                Text(backendSync.lastSyncError ?? "Connecting to server…")
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await backendSync.syncNow() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var filteredBackendEndpoints: [DashboardEndpointInfo] {
        guard let dashboard = backendSync.dashboardData else { return [] }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dashboard.endpoints }
        return dashboard.endpoints.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.url.localizedCaseInsensitiveContains(trimmed)
                || ($0.groupName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search endpoints", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filteredEndpoints: [Endpoint] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return endpointStore.endpoints }
        return endpointStore.endpoints.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(trimmed)
                || ($0.group?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var groupedSections: [EndpointGroupSection] {
        filteredEndpoints.groupedByGroupName()
    }

    private func isLastRow(_ endpoint: Endpoint, in section: EndpointGroupSection) -> Bool {
        endpoint.id == section.endpoints.last?.id && section.id == groupedSections.last?.id
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            if title != EndpointGroupSection.ungroupedTitle {
                Circle().fill(GroupBadgeStyle.color(for: title)).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// Scrolling list area of the popover, sized to its content up to `maxHeight`.
///
/// A bare `ScrollView` with `.frame(maxHeight:)` has no height of its own to offer, and in the
/// live `MenuBarExtra` window panel (macOS 26) it collapsed to zero — the popover showed only the
/// search field and the footer. The content's height is measured instead and handed to the
/// `ScrollView` explicitly, so the panel never has to guess.
struct PopoverList<Content: View>: View {
    nonisolated static var maxHeight: CGFloat { 320 }

    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverListHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(PopoverListHeightKey.self) { contentHeight = $0 }
        .frame(height: Self.height(forContent: contentHeight))
    }

    /// Until the content has been measured, reserve the full height rather than none, so the
    /// first layout can't collapse.
    nonisolated static func height(forContent measured: CGFloat?) -> CGFloat {
        guard let measured, measured > 0 else { return maxHeight }
        return min(measured, maxHeight)
    }
}

private struct PopoverListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
