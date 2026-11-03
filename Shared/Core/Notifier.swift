import Foundation
import UserNotifications

/// Local notifications for timers, reminders and Screen Watch alerts.
enum Notifier {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    static func post(title: String, body: String) async {
        try? await schedule(title: title, body: body, after: nil)
    }

    /// Schedules a notification `after` seconds from now (nil = immediately).
    @discardableResult
    static func schedule(title: String, body: String, after seconds: TimeInterval?) async throws -> Date {
        guard await requestAuthorization() else {
            throw ToolError.invalid("Notifications are turned off for JARVIS. Enable them in Settings.")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        let fireDate = Date().addingTimeInterval(seconds ?? 0)
        if let seconds, seconds >= 1 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
        return fireDate
    }

    static func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }
}

/// Shows notifications as banners even while JARVIS is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
