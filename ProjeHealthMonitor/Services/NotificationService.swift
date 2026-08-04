import Foundation
import UserNotifications

/// Stateless wrapper around UNUserNotificationCenter — no actor affinity needed.
final class NotificationService: Sendable {
    func requestAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func notifyDown(endpointName: String, reason: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(endpointName) down!"
        content.body = reason ?? "Health check failed."
        content.sound = .default
        post(content)
    }

    func notifyRecovered(endpointName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(endpointName) is back up"
        content.body = "Health check succeeded again."
        content.sound = .default
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
