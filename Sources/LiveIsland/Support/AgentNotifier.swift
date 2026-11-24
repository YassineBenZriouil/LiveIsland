import AppKit
import LiveIslandCore
import UserNotifications

/// Tells the person an agent needs them when the island can't: it's hidden over a full-screen
/// app, or the screen is locked or asleep. It's opt-in (Settings › AI Agents), and goes through
/// Notification Center, so Focus and Do Not Disturb decide whether it shows or waits there.
///
/// The notification center is touched only once the setting is on: the first call asks macOS
/// for permission, and a build that isn't an app bundle (`swift run`) has none to ask.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// A tap on a notification: the session's id, to go to it.
    var onOpen: ((String) -> Void)?

    private var alerts = AgentAlerts()
    private var center: UNUserNotificationCenter?
    nonisolated private static let sessionKey = "session"

    /// Notification Center works only for a real app bundle; elsewhere it would crash.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func notificationCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Self.isAvailable else { return nil }
        let current = UNUserNotificationCenter.current()
        current.delegate = self
        center = current
        return current
    }

    /// Asks macOS once (it remembers the answer); `granted` is false when the person said no,
    /// or turned LiveIsland's notifications off in System Settings.
    func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let center = notificationCenter() else { return completion(false) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
        }
    }

    /// Every snapshot comes through, even with the setting off, so turning it on later doesn't
    /// announce what was already waiting. `unseen`: the island can't be seen right now.
    func observe(_ sessions: [AgentSession], enabled: Bool, unseen: Bool, hidingDetails: Bool) {
        let change = alerts.update(sessions)
        guard enabled, let center = notificationCenter() else { return }
        if !change.ended.isEmpty {
            // Answered: a banner left in Notification Center would only be noise.
            center.removeDeliveredNotifications(withIdentifiers: change.ended)
        }
        guard unseen else { return }
        for session in change.started {
            let message = AgentAlerts.message(for: session, hidingDetails: hidingDetails)
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default
            content.threadIdentifier = session.id
            content.userInfo = [Self.sessionKey: session.id]
            // `.active`, not time-sensitive: a Focus holds it back.
            content.interruptionLevel = .active
            center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Read here: the response itself isn't Sendable, so only its strings cross to the main thread.
        let id = response.notification.request.content.userInfo[Self.sessionKey] as? String
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id, opened { self.onOpen?(id) }
            }
        }
        completionHandler()
    }
}
