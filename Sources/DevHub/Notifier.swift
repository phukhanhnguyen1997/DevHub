import Foundation
import AppKit
import UserNotifications

extension Notification.Name {
    static let devhubOpenTarget = Notification.Name("devhub.openTarget")
}

/// Native notifications. Clicking one brings DevHub forward and opens the related tab/profile.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var asked = false

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        asked = true
    }

    static func post(_ title: String, _ body: String, tab: Tab, profile: UUID?) {
        let c = UNUserNotificationCenter.current()
        if !shared.asked { shared.setup() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: String] = ["tab": tab.rawValue]
        if let profile { info["profile"] = profile.uuidString }
        content.userInfo = info
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let info = r.notification.request.content.userInfo as? [String: String] ?? [:]
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
                w.deminiaturize(nil)
                w.makeKeyAndOrderFront(nil)
            }
            NotificationCenter.default.post(name: .devhubOpenTarget, object: nil, userInfo: info)
        }
    }
}
