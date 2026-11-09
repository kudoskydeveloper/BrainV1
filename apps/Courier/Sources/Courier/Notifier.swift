import AppKit
import CourierCore
import SwiftUI
import UserNotifications

/// New-mail notifications (by default only for people and invitations) and the Dock badge.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var model: AppModel?

    static func enabled(_ c: MailCategory) -> Bool {
        let key = "notify." + c.rawValue
        if UserDefaults.standard.object(forKey: key) == nil { return c == .people || c == .invites }
        return UserDefaults.standard.bool(forKey: key)
    }
    static func setEnabled(_ c: MailCategory, _ on: Bool) { UserDefaults.standard.set(on, forKey: "notify." + c.rawValue) }
    static var badgeOn: Bool {
        get { UserDefaults.standard.object(forKey: "dockBadge") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockBadge") }
    }

    func start(model: AppModel) {
        self.model = model
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ messages: [MessageSummary], accounts: [Account]) {
        let list = messages.filter { !$0.seen && Self.enabled($0.category) && $0.date > Date().addingTimeInterval(-6 * 3600) }
        guard !list.isEmpty else { return }
        let c = UNUserNotificationCenter.current()
        for m in list.prefix(3) {
            let n = UNMutableNotificationContent()
            n.title = m.fromDisplay
            n.subtitle = m.subject
            n.body = m.snippet
            n.sound = .default
            n.threadIdentifier = m.threadKey
            n.userInfo = ["id": m.id]
            if accounts.count > 1, let a = accounts.first(where: { $0.id == m.accountID }) { n.subtitle = "\(m.subject) · \(a.email)" }
            c.add(UNNotificationRequest(identifier: "m\(m.id)", content: n, trigger: nil))
        }
        if list.count > 3 {
            let n = UNMutableNotificationContent()
            n.title = "Courier"
            n.body = "Ďalších \(list.count - 3) nových správ"
            c.add(UNNotificationRequest(identifier: "more-\(UUID().uuidString)", content: n, trigger: nil))
        }
    }

    private var lastBadge: Int?
    private var badgePending = false

    /// The Dock badge, and the same number for Hangar's tile: written to
    /// ~/Library/Application Support/com.lockedin/badges/com.lockedin.courier and announced with the distributed notification
    /// "com.lockedin.badge", so Hangar shows it even when it starts later or Courier isn't running.
    func updateBadge(_ store: Store) {
        // unread in the inboxes from the groups you get notified about (by default people and invitations)
        // Called after every list reload: coalesce bursts into one count half a second later, and redraw the tile only on a change.
        guard !badgePending else { return }
        badgePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            badgePending = false
            let n = Self.badgeOn ? store.unifiedInbox(unreadOnly: true, limit: 5000).filter { Self.enabled($0.category) }.count : 0
            guard n != lastBadge else { return }
            lastBadge = n
            Self.drawDockBadge(n)
            Self.publish(n)
        }
    }

    /// The Dock badge drawn into the tile by Courier itself: macOS hides the system badge (`badgeLabel`) when the app's
    /// notifications aren't allowed to badge, and the count should show either way.
    static func drawDockBadge(_ n: Int) {
        let tile = NSApp.dockTile
        tile.badgeLabel = nil
        if n > 0 {
            let v = (tile.contentView as? BadgeTileView) ?? BadgeTileView(frame: NSRect(origin: .zero, size: tile.size))
            v.count = n
            tile.contentView = v
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    static func publish(_ n: Int) {
        let id = Bundle.main.bundleIdentifier ?? "com.lockedin.courier"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.lockedin/badges")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(n)".write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(.init("com.lockedin.badge"), object: id, userInfo: ["count": n],
                                                                     deliverImmediately: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["id"] as? NSNumber)?.int64Value
        await MainActor.run {
            NSApp.activate()
            if let id, let m = model?.store.message(id: id) { model?.show(m) }
        }
    }
}

struct NotificationSettings: View {
    @State private var tick = 0
    var body: some View {
        Form {
            Section("Upozorniť na novú poštu") {
                ForEach(MailCategory.allCases) { c in
                    Toggle(isOn: Binding(get: { _ = tick; return Notifier.enabled(c) }, set: {
                        Notifier.setEnabled(c, $0); tick += 1
                        if let m = Notifier.shared.model { Notifier.shared.updateBadge(m.store) }
                    })) {
                        Label(c.title, systemImage: c.symbol)
                    }
                }
            }
            Section {
                Toggle("Počet neprečítaných v Docku a v Hangari (skupiny s upozornením)", isOn: Binding(get: { _ = tick; return Notifier.badgeOn }, set: { Notifier.badgeOn = $0; tick += 1; if let m = Notifier.shared.model { Notifier.shared.updateBadge(m.store) } }))
            } footer: {
                Text("Doručená pošta sa kontroluje každú minútu, kým Courier beží.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The app icon with a red count in its top right corner, like the Dock's own badge.
final class BadgeTileView: NSView {
    var count = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirty: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let text = count > 99 ? "99+" : "\(count)"
        // the Dock's own badge: a solid red circle about 40 % of the tile, white semibold number, soft shadow
        let h = (bounds.height * 0.40).rounded()
        let font = NSFont.systemFont(ofSize: h * 0.60, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = max(h, size.width + h * 0.6)
        let r = NSRect(x: bounds.maxX - w, y: bounds.maxY - h, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = h * 0.06
        shadow.shadowOffset = NSSize(width: 0, height: -h * 0.03)
        shadow.set()
        NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: h * 0.04, dy: h * 0.04), xRadius: h / 2, yRadius: h / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 + h * 0.02), withAttributes: attrs)
    }
}
