import Foundation

/// Latest parsed health-standard response per endpoint (status, reason, version), shown in
/// `EndpointDetailView`'s Reported health section. Deliberately in-memory only and one entry per
/// endpoint: it is a "right now" view, so it never bloats persisted history and is simply refilled
/// by the first check after a relaunch.
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
