import AppKit
import UserNotifications

/// Native notifications. Clicking a brief notification opens the brief window.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpenBrief: (() -> Void)?

    func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String, opensBrief: Bool = false, sound: String? = nil) {
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = sound.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        n.userInfo = ["brief": opensBrief]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id + "-\(Date().timeIntervalSince1970)", content: n, trigger: nil))
    }

    /// A notification at a set time (skipped if that time has passed); sound is a file in the app's Resources, nil = default.
    static func schedule(title: String, body: String, id: String, at: Date, sound: String?) {
        let wait = at.timeIntervalSinceNow
        guard wait > 1 else { return }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = sound.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        n.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: n,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
    }

    static func cancel(_ ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }

    // show banners even though the app counts as active
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpenBrief?() }
        done()
    }
}
