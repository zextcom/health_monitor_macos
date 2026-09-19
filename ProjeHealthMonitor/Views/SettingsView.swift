import SwiftUI
import ServiceManagement
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var endpointStore: EndpointStore
    @EnvironmentObject var historyStore: HealthHistoryStore
    @EnvironmentObject var dailyStatsStore: DailyStatsStore
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var backendAuth: BackendAuthStore
    @EnvironmentObject var backendSync: BackendSyncService
    @State private var editingEndpoint: Endpoint?
    @State private var isPresentingForm = false
    @State private var launchAtLoginError: String?
    @State private var intervalSelection: IntervalSelection = .preset(60)
    @State private var retentionSelection: RetentionSelection = .preset(7)
    @State private var endpointFileError: String?
    @State private var pendingDeletion: [Endpoint] = []
    @State private var selectedEndpointForDetail: Endpoint?
    @State private var serverEmail = ""
    @State private var serverPassword = ""

    private enum IntervalSelection: Hashable {
        case preset(TimeInterval)
        case custom
    }

    private enum RetentionSelection: Hashable {
        case preset(Int)
        case custom
    }

    private static let presets: [TimeInterval] = [30, 60, 300]
    private static let retentionPresets = [1, 7, 30]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            serverTab
                .tabItem { Label("Server", systemImage: "cloud") }
            endpointsTab
                .tabItem { Label("Endpoints", systemImage: "network") }
            statsTab
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 420)
        .sheet(isPresented: $isPresentingForm) {
            EndpointFormView(endpoint: editingEndpoint) { result in
                if case .save(let endpoint, let secretUpdate) = result {
                    switch secretUpdate {
                    case .set(let value): SecretStore.setSecret(value, for: endpoint.id.uuidString)
                    case .cleared: SecretStore.deleteSecret(for: endpoint.id.uuidString)
                    case .unchanged: break
                    }
                    if endpointStore.endpoints.contains(where: { $0.id == endpoint.id }) {
                        endpointStore.updateEndpoint(endpoint)
                    } else {
                        endpointStore.addEndpoint(endpoint)
                    }
                }
                isPresentingForm = false
            }
        }
    }

    // MARK: - Endpoints

    private var endpointsTab: some View {
        VStack(spacing: 0) {
            if endpointStore.endpoints.isEmpty {
                Spacer()
                Text("No endpoints added yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(groupedEndpointSections) { section in
                        Section {
                            ForEach(section.endpoints) { endpoint in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(endpoint.name).font(.headline)
                                            if HealthCheckService.isSnoozed(endpoint) {
                                                Image(systemName: "moon.zzz.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                        Text(endpoint.url.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Edit") {
                                        editingEndpoint = endpoint
                                        isPresentingForm = true
                                    }
                                }
                            }
                            .onDelete { offsets in
                                pendingDeletion = offsets.map { section.endpoints[$0] }
                            }
                        } header: {
                            if groupedEndpointSections.count > 1 {
                                HStack(spacing: 6) {
                                    if section.title != EndpointGroupSection.ungroupedTitle {
                                        Circle().fill(GroupBadgeStyle.color(for: section.title)).frame(width: 6, height: 6)
                                    }
                                    Text(section.title)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            if let endpointFileError {
                Text(endpointFileError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            HStack {
                Button {
                    exportEndpoints()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(endpointStore.endpoints.isEmpty)
                Button {
                    importEndpoints()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportStatusPage()
                } label: {
                    Label("Export Status Page…", systemImage: "globe")
                }
                .disabled(endpointStore.endpoints.isEmpty)
                Spacer()
                Button {
                    editingEndpoint = nil
                    isPresentingForm = true
                } label: {
                    Label("Add Endpoint", systemImage: "plus")
                }
            }
            .padding()
            Text("Export/import saves endpoint configuration only — authentication secrets aren't included and must be re-entered after import.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .confirmationDialog(deletionDialogTitle, isPresented: isPendingDeletionPresented, titleVisibility: .visible) {
            Button("Delete History Too", role: .destructive) { confirmDeletion(retainData: false) }
            Button("Keep History") { confirmDeletion(retainData: true) }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("Keeping history reattaches it automatically if you add a new endpoint with the same URL later. Unused history is purged automatically after \(EndpointStore.retainedDataExpiryDays) days.")
        }
    }

    private var groupedEndpointSections: [EndpointGroupSection] {
        endpointStore.endpoints.groupedByGroupName()
    }

    private var isPendingDeletionPresented: Binding<Bool> {
        Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
    }

    private var deletionDialogTitle: String {
        pendingDeletion.count == 1
            ? "Delete \"\(pendingDeletion[0].name)\"?"
            : "Delete \(pendingDeletion.count) Endpoints?"
    }

    private func confirmDeletion(retainData: Bool) {
        for endpoint in pendingDeletion {
            endpointStore.removeEndpoint(id: endpoint.id, retainData: retainData)
            SecretStore.deleteSecret(for: endpoint.id.uuidString)
            if !retainData {
                historyStore.removeHistory(for: endpoint.id)
                dailyStatsStore.removeStats(for: endpoint.id)
            }
        }
        pendingDeletion = []
    }

    private func exportEndpoints() {
        guard let data = endpointStore.exportData() else {
            endpointFileError = "Couldn't prepare endpoints for export"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "health-monitor-endpoints.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            endpointFileError = nil
        } catch {
            endpointFileError = "Couldn't save file: \(error.localizedDescription)"
        }
    }

    private func importEndpoints() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try endpointStore.importEndpoints(from: data)
            endpointFileError = nil
        } catch {
            endpointFileError = "Couldn't import file: \(error.localizedDescription)"
        }
    }

    /// Builds `EndpointStatusSummary`s from live store data — this is the store-touching glue that
    /// `HealthCheckService.statusPageHTML`/`statusPageJSON` deliberately stay free of (same split
    /// as `EndpointDetailView`, which reads `historyStore.results(for:)` directly rather than
    /// pushing store access down into `HealthCheckService`).
    private func statusSummaries() -> [HealthCheckService.EndpointStatusSummary] {
        endpointStore.endpoints.map { endpoint in
            let results = historyStore.results(for: endpoint.id)
            return HealthCheckService.EndpointStatusSummary(
                name: endpoint.name,
                group: endpoint.group,
                isHealthy: results.last?.isHealthy,
                uptimePercentage: HealthCheckService.uptimePercentage(results: results),
                lastCheckedAt: results.last?.timestamp,
                isSnoozed: HealthCheckService.isSnoozed(endpoint)
            )
        }
    }

    /// Unlike `exportEndpoints()`/`importEndpoints()` above (one file each), this produces two
    /// files — `status.html` + `status.json` — from a single click, so the user picks a
    /// destination folder rather than a single file name.
    private func exportStatusPage() {
        let generatedAt = Date()
        let summaries = statusSummaries()
        let html = HealthCheckService.statusPageHTML(summaries: summaries, generatedAt: generatedAt)
        let json = HealthCheckService.statusPageJSON(summaries: summaries, generatedAt: generatedAt)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder to export status.html and status.json into"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            try Data(html.utf8).write(to: folderURL.appendingPathComponent("status.html"), options: .atomic)
            try json.write(to: folderURL.appendingPathComponent("status.json"), options: .atomic)
            endpointFileError = nil
        } catch {
            endpointFileError = "Couldn't export status page: \(error.localizedDescription)"
        }
    }

    // MARK: - Server

    private var serverTab: some View {
        Form {
            Section {
                TextField("Server URL", text: $backendAuth.serverURL, prompt: Text("https://health.zext.dev"))
                    .textFieldStyle(.roundedBorder)
                Text("The URL of your Health Monitor backend server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Backend Server", systemImage: "globe")
            }

            if backendAuth.isConnected, let user = backendAuth.currentUser {
                Section {
                    LabeledContent("Email", value: user.email)
                    LabeledContent("Name", value: user.name)
                    LabeledContent("Role", value: user.role)
                    Button("Disconnect", role: .destructive) {
                        backendAuth.disconnect()
                    }
                } header: {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                }

                if let dashboard = backendSync.dashboardData {
                    Section {
                        LabeledContent("Total Endpoints", value: "\(dashboard.summary.totalEndpoints)")
                        LabeledContent("Healthy", value: "\(dashboard.summary.healthyEndpoints)")
                        LabeledContent("Unhealthy", value: "\(dashboard.summary.unhealthyEndpoints)")
                        LabeledContent("Overall Uptime", value: String(format: "%.1f%%", dashboard.summary.overallUptimePercent))
                        Button("Sync Now") {
                            Task { await backendSync.syncNow() }
                        }
                        .disabled(backendSync.isSyncing)
                    } header: {
                        Label("Dashboard", systemImage: "chart.bar")
                    }
                }

                if let error = backendSync.lastSyncError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    } header: {
                        Label("Sync Error", systemImage: "exclamationmark.triangle")
                    }
                }
            } else {
                Section {
                    TextField("Email", text: $serverEmail)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $serverPassword)
                        .textFieldStyle(.roundedBorder)

                    if let error = backendAuth.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Button {
                        Task {
                            await backendAuth.connect(email: serverEmail, password: serverPassword)
                            if backendAuth.isConnected {
                                serverEmail = ""
                                serverPassword = ""
                            }
                        }
                    } label: {
                        if backendAuth.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(serverEmail.isEmpty || serverPassword.isEmpty || backendAuth.serverURL.isEmpty || backendAuth.isLoading)
                } header: {
                    Label("Login", systemImage: "person.circle")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Check frequency", selection: $intervalSelection) {
                    Text("30 seconds").tag(IntervalSelection.preset(30))
                    Text("1 minute").tag(IntervalSelection.preset(60))
                    Text("5 minutes").tag(IntervalSelection.preset(300))
                    Text("Custom").tag(IntervalSelection.custom)
                }
                if intervalSelection == .custom {
                    HStack {
                        Text("Custom (seconds)")
                        TextField("", value: $endpointStore.globalCheckInterval, format: .number)
                            .frame(width: 80)
                    }
                }
            } header: {
                Label("Check Frequency", systemImage: "clock")
            }

            Section {
                HStack {
                    Text("Timeout (seconds)")
                    TextField("", value: $endpointStore.requestTimeout, format: .number)
                        .frame(width: 80)
                }
            } header: {
                Label("Request Timeout", systemImage: "timer")
            }

            Section {
                Picker("Keep history for", selection: $retentionSelection) {
                    Text("1 day").tag(RetentionSelection.preset(1))
                    Text("7 days").tag(RetentionSelection.preset(7))
                    Text("30 days").tag(RetentionSelection.preset(30))
                    Text("Custom").tag(RetentionSelection.custom)
                }
                if retentionSelection == .custom {
                    HStack {
                        Text("Custom (days)")
                        TextField("", value: $endpointStore.historyRetentionDays, format: .number)
                            .frame(width: 80)
                    }
                }
                Text("Applies to per-check history (response time chart, incidents, export). A shorter interval with a longer window keeps more raw data on disk.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("History Retention", systemImage: "clock.arrow.circlepath")
            }

            Section {
                Toggle("Notify when down", isOn: $endpointStore.notificationsEnabled)
                Toggle("Notify when recovered", isOn: $endpointStore.notifyOnRecovery)
                    .disabled(!endpointStore.notificationsEnabled)
            } header: {
                Label("Notifications", systemImage: "bell")
            }

            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Label("Startup", systemImage: "power")
            }

            Section {
                KeyboardShortcuts.Recorder("Open Settings:", name: .openSettings)
                Text("Opens Settings from anywhere — the popover itself can't be toggled from a global shortcut (a SwiftUI/MenuBarExtra limitation).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Shortcuts", systemImage: "keyboard")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncIntervalSelection()
            syncRetentionSelection()
        }
        .onChange(of: intervalSelection) { newValue in
            if case .preset(let seconds) = newValue {
                endpointStore.globalCheckInterval = seconds
            }
        }
        .onChange(of: retentionSelection) { newValue in
            if case .preset(let days) = newValue {
                endpointStore.historyRetentionDays = days
            }
        }
    }

    private func syncIntervalSelection() {
        if Self.presets.contains(endpointStore.globalCheckInterval) {
            intervalSelection = .preset(endpointStore.globalCheckInterval)
        } else {
            intervalSelection = .custom
        }
    }

    private func syncRetentionSelection() {
        if Self.retentionPresets.contains(endpointStore.historyRetentionDays) {
            retentionSelection = .preset(endpointStore.historyRetentionDays)
        } else {
            retentionSelection = .custom
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { endpointStore.launchAtLoginEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    endpointStore.launchAtLoginEnabled = newValue
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Stats

    private var statsTab: some View {
        VStack(spacing: 0) {
            if endpointStore.endpoints.isEmpty {
                Spacer()
                Text("No endpoints added yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(endpointStore.endpoints) { endpoint in
                        Button {
                            selectedEndpointForDetail = endpoint
                        } label: {
                            EndpointStatsRowView(
                                endpoint: endpoint,
                                dailyStats: dailyStatsStore.dailyStats(for: endpoint.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selectedEndpointForDetail) { endpoint in
            EndpointDetailView(endpoint: endpoint)
                .environmentObject(historyStore)
        }
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: automaticallyChecksBinding)
                HStack {
                    Button("Check for Updates Now") {
                        updaterViewModel.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)
                    Spacer()
                }
            } header: {
                Label("Software Updates", systemImage: "arrow.down.circle")
            }
        }
        .formStyle(.grouped)
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updaterViewModel.automaticallyChecksForUpdates },
            set: { updaterViewModel.automaticallyChecksForUpdates = $0 }
        )
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(appDisplayName)
                .font(.title2.bold())
            Text("Version \(shortVersion) (\(buildVersion))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(bundleIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .frame(width: 200)
            Text("Menu bar health check monitor for your endpoints.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var appDisplayName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Health Monitor"
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "-"
    }
}
