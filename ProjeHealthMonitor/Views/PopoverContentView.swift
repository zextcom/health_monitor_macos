import SwiftUI
import AppKit

struct PopoverContentView: View {
    @EnvironmentObject var endpointStore: EndpointStore
    @EnvironmentObject var historyStore: HealthHistoryStore
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if endpointStore.endpoints.isEmpty {
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(groupedSections) { section in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(section.title)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 4)

                                    ForEach(section.endpoints) { endpoint in
                                        EndpointRowView(endpoint: endpoint, results: historyStore.results(for: endpoint.id))
                                        if endpoint.id != section.endpoints.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                if section.id != groupedSections.last?.id {
                                    Divider()
                                        .padding(.top, 4)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }
                    .frame(maxHeight: 320)
                }
            }

            Divider()

            HStack {
                Button("Settings") { presentSettingsWindow(using: openWindow) }
                    .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(width: 320)
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
        endpointStore.filteredEndpoints(matching: searchText)
    }

    private var groupedSections: [EndpointGroupSection] {
        endpointStore.groupedSections(for: filteredEndpoints)
    }
}
