import Foundation

/// Latest parsed health-standard response per endpoint (status, version, component checks), shown
/// in `EndpointDetailView`'s Components section. Deliberately in-memory only and one entry per
/// endpoint: components are a "right now" view, so they never bloat persisted history and are
/// simply refilled by the first check after a relaunch.
@MainActor
final class HealthDetailsStore: ObservableObject {
    struct Entry: Equatable {
        let response: HealthStandardResponse
        let checkedAt: Date
    }

    @Published private(set) var latest: [UUID: Entry] = [:]

    func details(for endpointId: UUID) -> Entry? {
        latest[endpointId]
    }

    func record(_ response: HealthStandardResponse, for endpointId: UUID, at date: Date = Date()) {
        latest[endpointId] = Entry(response: response, checkedAt: date)
    }

    func remove(for endpointId: UUID) {
        latest.removeValue(forKey: endpointId)
    }
}
