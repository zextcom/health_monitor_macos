import Foundation
import UserNotifications

/// Narrow seam over `UNUserNotificationCenter` — exposes only what `NotificationService` needs,
/// so tests can substitute a fake instead of touching the real system notification center.
protocol UserNotificationCentering: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Stateless wrapper around UNUserNotificationCenter — no actor affinity needed.
final class NotificationService: Sendable {
    private let center: UserNotificationCentering

    init(center: UserNotificationCentering = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() {
        Task { await requestAuthorizationIfNeededAsync() }
    }

    func requestAuthorizationIfNeededAsync() async {
        let status = await center.authorizationStatus()
        guard status == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyDown(endpointName: String, reason: String?) {
        Task { await notifyDownAsync(endpointName: endpointName, reason: reason) }
    }

    func notifyDownAsync(endpointName: String, reason: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "\(endpointName) down!"
        content.body = reason ?? "Health check failed."
        content.sound = .default
        await post(content)
    }

    func notifyRecovered(endpointName: String) {
        Task { await notifyRecoveredAsync(endpointName: endpointName) }
    }

    func notifyRecoveredAsync(endpointName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(endpointName) is back up"
        content.body = "Health check succeeded again."
        content.sound = .default
        await post(content)
    }

    func notifyCertificateExpiringSoon(endpointName: String, daysRemaining: Int) {
        Task { await notifyCertificateExpiringSoonAsync(endpointName: endpointName, daysRemaining: daysRemaining) }
    }

    func notifyCertificateExpiringSoonAsync(endpointName: String, daysRemaining: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(endpointName) certificate expiring soon"
        content.body = daysRemaining >= 0
            ? "TLS certificate expires in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")."
            : "TLS certificate has expired."
        content.sound = .default
        await post(content)
    }

    private func post(_ content: UNMutableNotificationContent) async {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        _ = try? await center.add(request)
    }
}
