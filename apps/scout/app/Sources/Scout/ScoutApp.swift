import AppKit
import SwiftUI

@main
struct ScoutApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate


    var body: some Scene {
        Window("Scout", id: "main") { ContentView(store: .shared) }
            .defaultSize(width: 1100, height: 720)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {}
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
        Task { @MainActor in Store.shared.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// scout://company/<domain>, scout://person?name=…&domain=…, scout://people, scout://blocked, scout://refresh.
    /// The store is created on first use, so this works also when the URL starts the app.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "scout" {
            Task { @MainActor in
                let s = Store.shared
                let path = [url.host, url.path.isEmpty ? nil : String(url.path.dropFirst())].compactMap { $0 }.joined(separator: "/")
                switch path {
                case "refresh": s.refresh()
                case "": s.pendingSelection = "companies"
                default:
                    s.pendingQuery = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                    s.pendingSelection = path
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
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Scout" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            Store.shared.openMain?()
        }
    }
}
