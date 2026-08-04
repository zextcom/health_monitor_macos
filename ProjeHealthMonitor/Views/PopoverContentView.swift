import SwiftUI
import AppKit

struct PopoverContentView: View {
    @EnvironmentObject var endpointStore: EndpointStore
    @EnvironmentObject var historyStore: HealthHistoryStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if endpointStore.endpoints.isEmpty {
                VStack(spacing: 8) {
                    Text("No endpoints added yet")
                        .foregroundStyle(.secondary)
                    Button("Add in Settings") {
                        openWindow(id: "settings")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(endpointStore.endpoints) { endpoint in
                            EndpointRowView(endpoint: endpoint, results: historyStore.results(for: endpoint.id))
                            if endpoint.id != endpointStore.endpoints.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Button("Settings") { openWindow(id: "settings") }
                    .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(width: 320)
    }
}
