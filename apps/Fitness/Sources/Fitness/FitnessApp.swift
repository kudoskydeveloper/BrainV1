import AppKit
import SwiftUI

@main
struct FitnessApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate

    init() { Snapshot.runIfAsked() }

    var body: some Scene {
        Window("Fitness", id: "main") { ContentView(store: .shared) }
            .defaultSize(width: 1080, height: 760)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .toolbar) {
                    Button("Obnoviť") { Store.shared.refresh() }.keyboardShortcut("r")
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
        Task { @MainActor in Store.shared.refresh() }
    }

    /// fitness://overview (Hangar: open the window) and fitness://refresh (load fresh data now).
    /// The store is created on first use, so this works also when the URL starts the app.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "fitness" {
            Task { @MainActor in
                if url.host == "refresh" { Store.shared.refresh() }
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
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Fitness" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            Store.shared.openMain?()
        }
    }
}
