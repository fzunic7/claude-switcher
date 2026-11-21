import Foundation
import UserNotifications

/// Shows notifications while the app is "in front" and routes the "Switch to …" button back to the model.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let lowUsageCategory = "LOW_USAGE"
    static let switchAction = "SWITCH"

    weak var model: AppModel?

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.switchAction, title: "Switch", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.lowUsageCategory, actions: [action], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = response.notification.request.content.userInfo["targetId"] as? String
        let tapped = response.actionIdentifier == Self.switchAction
        completionHandler()
        guard tapped, let target else { return }
        Task { @MainActor [weak model] in await model?.switchTo(accountId: target) }
    }
}
