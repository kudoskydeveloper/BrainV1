import AppKit
import FinancieCore
import SwiftUI

@main
struct FinancieApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate
    @ObservedObject private var lock = Lock.shared

    init() { Demo.applyArguments(); Snapshot.runIfAsked() }

    var body: some Scene {
        Window("Financie", id: "main") { ContentView(model: .shared, lock: .shared) }
            .defaultSize(width: 1280, height: 840)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Nový výdavok") { AppModel.shared.newTransaction(.expense) }.keyboardShortcut("n").disabled(lock.locked)
                    Button("Nový príjem") { AppModel.shared.newTransaction(.income) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(lock.locked)
                    Button("Nový prevod") { AppModel.shared.newTransaction(.transfer) }.keyboardShortcut("n", modifiers: [.command, .option]).disabled(lock.locked)
                    Divider()
                    Button("Nová pravidelná položka") { AppModel.shared.newRecurring() }.disabled(lock.locked)
                    Button("Nový účet") { AppModel.shared.newAccount() }.disabled(lock.locked)
                }
                CommandMenu("Financie") {
                    Button("Prehľad") { AppModel.shared.page = .overview }.keyboardShortcut("1")
                    Button("Pohyby") { AppModel.shared.page = .transactions }.keyboardShortcut("2")
                    Button("Čaká") { AppModel.shared.page = .waiting }.keyboardShortcut("3")
                    Button("Pravidelné") { AppModel.shared.page = .recurring }.keyboardShortcut("4")
                    Divider()
                    Button("Obnoviť") { AppModel.shared.reload() }.keyboardShortcut("r")
                    Divider()
                    Button("Zamknúť Financie") { Lock.shared.lock(byHand: true) }.keyboardShortcut("l", modifiers: [.command, .control])
                    Divider()
                    Button("Zálohovať teraz") { AppModel.shared.backupNow() }
                    Button("Otvoriť priečinok so zálohami") { NSWorkspace.shared.open(Backup.root) }
                }
            }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
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

    private var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            Backup.runIfDue(AppModel.shared.store)
            self.timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
                Task { @MainActor in Backup.runIfDue(AppModel.shared.store); AppModel.shared.reload() }
            }
        }
    }

    /// financie://new, new-income, transfer, overview, transactions, waiting, recurring, account/<id>.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "financie" {
            Task { @MainActor in
                let m = AppModel.shared
                switch url.host {
                case "new", "new-expense": m.newTransaction(.expense)
                case "new-income": m.newTransaction(.income)
                case "transfer": m.newTransaction(.transfer)
                case "transactions": m.page = .transactions
                case "waiting": m.page = .waiting
                case "recurring": m.page = .recurring
                case "account": if let id = Int64(url.lastPathComponent) { m.page = .account(id) }
                default: m.page = .overview
                }
                Delegate.showWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Delegate.showWindow() }
        return true
    }

    @MainActor static func showWindow() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.title == "Financie" || $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            AppModel.shared.openMain?()
        }
    }
}
