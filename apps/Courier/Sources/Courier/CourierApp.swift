import AppKit
import CourierCore
import SwiftUI

struct CourierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // one mail window (a WindowGroup opened a new one for every courier:// link and on ⌘N-style reopen)
        Window("Courier", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { ControlServer.shared.start(model: model) }
        }
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: [])
        .commands { CourierCommands(model: model) }

        WindowGroup("Nová správa", id: "compose", for: UUID.self) { $id in
            if let id { ComposeView(id: id).environmentObject(model) }
        }
        .defaultSize(width: 720, height: 620)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])   // links never open an empty compose window

        Settings { SettingsView().environmentObject(model) }
    }
}

struct CourierCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @AppStorage("thread.newestFirst") private var newestFirst = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nová správa") { openWindow(id: "compose", value: model.newDraft()) }.keyboardShortcut("n")
            Divider()
            Button("Pridať účet…") { model.showAddAccount = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Nový projekt…") { model.editingProject = Project(name: "") }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Adresár") { model.showContactsTab = true; model.selection = .contacts }.keyboardShortcut("k", modifiers: [.command, .shift])
            Toggle("Adresár v bočnom paneli", isOn: $model.showContactsTab)
            Toggle("Najnovšie správy vo vlákne hore", isOn: $newestFirst)
            Divider()
        }
        CommandMenu("Správa") {
            Button("Odpovedať") { reply(.reply) }.keyboardShortcut("r").disabled(model.selectedMessage == nil)
            Button("Odpovedať všetkým") { reply(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.selectedMessage == nil)
            Button("Preposlať") { reply(.forward) }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.selectedMessage == nil)
            Divider()
            Button(model.selectedMessage.map(model.isJunk) == true ? "Nie je spam" : "Spam") {
                if let m = model.selectedMessage { model.markSpam(m, !model.isJunk(m)) }
            }
            .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(model.selectedMessage == nil)
            Divider()
            Button("Obnoviť poštu") { Task { await model.refreshAll() } }.keyboardShortcut("r", modifiers: [.command, .option])
        }
    }

    func reply(_ k: AppModel.ReplyKind) {
        guard let m = model.conversation.last ?? model.selectedMessage else { return }
        openWindow(id: "compose", value: model.replyDraft(m, k))
    }
}

extension Notification.Name { static let courierURL = Notification.Name("courierURL") }

/// Opens the one Courier window when it was closed (set by ContentView from SwiftUI's openWindow).
@MainActor enum MainWindow {
    static var open: (() -> Void)?

    /// Brings the Courier window up; false when it had to be opened first.
    @discardableResult static func show() -> Bool {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return true
        }
        open?()
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One copy of the app only, like its one window: a second launch (another build of the app, say) brings the running
    /// copy forward and quits. Render and test runs (arguments starting with --) are left alone.
    func applicationWillFinishLaunching(_ n: Notification) {
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) {
            other.activate()
            exit(0)
        }
    }

    /// courier://inbox, courier://compose (used by Hangar).
    func application(_ application: NSApplication, open urls: [URL]) {
        let courier = urls.filter { $0.scheme == "courier" }
        guard !courier.isEmpty else { return }
        Task { @MainActor in
            // a window that had to be opened first gets the links once it is listening
            if !MainWindow.show() { try? await Task.sleep(for: .milliseconds(600)) }
            for u in courier { NotificationCenter.default.post(name: .courierURL, object: u) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { @MainActor in MainWindow.show() } }
        return true
    }
}

// MARK: Shared look

enum ProjectColor: String, CaseIterable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray
    var color: Color {
        switch self {
        case .blue: .blue; case .indigo: .indigo; case .purple: .purple; case .pink: .pink; case .red: .red; case .orange: .orange
        case .yellow: .yellow; case .green: .green; case .mint: .mint; case .teal: .teal; case .gray: .gray
        }
    }
    static func of(_ name: String) -> Color { (ProjectColor(rawValue: name) ?? .blue).color }
}

/// Round avatar with initials, colored by the address so a sender always keeps the same color (like chat apps).
struct Avatar: View {
    let name: String
    let address: String
    var size: CGFloat = 38

    var initials: String {
        let words = (name.isEmpty ? address.components(separatedBy: "@").first ?? address : name)
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }).filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var tint: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .mint, .teal, .cyan, .brown]
        let h = address.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(h % UInt32(palette.count))]
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white))
    }
}

extension Date {
    /// Chat-style time: 14:05 today, "včera", weekday this week, otherwise a short date.
    var listLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "včera" }
        if let d = cal.dateComponents([.day], from: self, to: Date()).day, d < 7 { return formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(self, equalTo: Date(), toGranularity: .year) { return formatted(.dateTime.day().month(.abbreviated)) }
        return formatted(date: .numeric, time: .omitted)
    }
}
