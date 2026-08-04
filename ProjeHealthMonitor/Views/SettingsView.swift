import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var endpointStore: EndpointStore
    @State private var editingEndpoint: Endpoint?
    @State private var isPresentingForm = false
    @State private var launchAtLoginError: String?
    @State private var intervalSelection: IntervalSelection = .preset(60)

    private enum IntervalSelection: Hashable {
        case preset(TimeInterval)
        case custom
    }

    private static let presets: [TimeInterval] = [30, 60, 300]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            endpointsTab
                .tabItem { Label("Endpoints", systemImage: "network") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 420)
        .sheet(isPresented: $isPresentingForm) {
            EndpointFormView(endpoint: editingEndpoint) { result in
                if case .save(let endpoint) = result {
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
                    ForEach(endpointStore.endpoints) { endpoint in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(endpoint.name).font(.headline)
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
                    .onDelete { indexSet in
                        for index in indexSet {
                            endpointStore.removeEndpoint(id: endpointStore.endpoints[index].id)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    editingEndpoint = nil
                    isPresentingForm = true
                } label: {
                    Label("Add Endpoint", systemImage: "plus")
                }
            }
            .padding()
        }
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
        }
        .formStyle(.grouped)
        .onAppear { syncIntervalSelection() }
        .onChange(of: intervalSelection) { newValue in
            if case .preset(let seconds) = newValue {
                endpointStore.globalCheckInterval = seconds
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
            ?? "Proje Health Monitor"
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
