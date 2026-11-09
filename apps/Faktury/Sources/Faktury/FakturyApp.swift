import AppKit
import FakturyCore
import SwiftUI

@main
struct FakturyApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate

    init() { Snapshot.runIfAsked() }

    var body: some Scene {
        Window("Faktúry", id: "main") { ContentView(model: .shared) }
            .defaultSize(width: 1440, height: 880)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Nová faktúra") { AppModel.shared.newInvoice(kind: .invoice) }.keyboardShortcut("n")
                    Button("Nová zálohová faktúra") { AppModel.shared.newInvoice(kind: .proforma) }.keyboardShortcut("n", modifiers: [.command, .shift])
                    Divider()
                    Button("Nový odberateľ") { AppModel.shared.editClient(Client()) }
                    Button("Nový subjekt…") { AppModel.shared.editCompany(Company()) }
                }
                CommandGroup(after: .importExport) {
                    Button("Export pre účtovníčku…") { AppModel.shared.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Zálohovať teraz") { AppModel.shared.backupNow() }
                    Button("Otvoriť priečinok so zálohami") { NSWorkspace.shared.open(Backup.root) }
                    Divider()
                    Button("Import starých faktúr…") { AppModel.shared.showImport = true }
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

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in AppModel.shared.startBackups() }
    }

    /// faktury://new, faktury://new-proforma, faktury://unpaid, faktury://overdue, faktury://drafts, faktury://invoice/<id>.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "faktury" {
            Task { @MainActor in
                let m = AppModel.shared
                switch url.host {
                case "new": m.newInvoice(kind: .invoice)
                case "new-proforma": m.newInvoice(kind: .proforma)
                case "unpaid": m.folder = .unpaid
                case "overdue": m.folder = .overdue
                case "drafts": m.folder = .drafts
                case "paid": m.folder = .paid
                case "clients": m.folder = .clients
                case "overview": m.folder = .overview
                case "invoice":
                    if let id = Int64(url.lastPathComponent), let i = m.store.invoice(id) { m.folder = .company(i.companyId); m.selection = .invoice(id) }
                default: break
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
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Faktúry" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            AppModel.shared.openMain?()
        }
    }
}
