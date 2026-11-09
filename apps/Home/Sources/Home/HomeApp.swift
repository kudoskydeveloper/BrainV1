import AppKit
import HomeCore
import SwiftUI

extension Store {
    @MainActor static let shared = Store()
}

extension Devices {
    @MainActor static let shared = Devices()
}

@main
struct HomeApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate

    init() { Snapshot.runIfAsked() }

    var body: some Scene {
        Window("Home", id: "main") {
            ContentView()
                .environment(Store.shared)
                .environment(Events.shared)
                .environment(AppState.shared)
                .environment(Devices.shared)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Synchronizovať") { Task { await Store.shared.sync() } }.keyboardShortcut("r")
            }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    @MainActor static var openMain: (() -> Void)?
    private var timer: Timer?

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
        Task { @MainActor in await Store.shared.sync() }
        // Changes from the other members every 30 s; the MCP server's changes are in the file by then too.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                if Store.shared.pendingCount == 0 { Store.shared.reloadFromDisk() }
                await Store.shared.sync()
            }
        }
    }

    func applicationDidBecomeActive(_ n: Notification) {
        Task { @MainActor in await Store.shared.sync() }
    }

    /// The app keeps syncing with its window closed (Brain reads the same data).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    /// home://auth#… (the sign-in link from the e-mail), home://today, home://tasks, home://shopping, home://plan,
    /// home://devices, home://household (Hangar), home://sync.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "home" {
            Task { @MainActor in
                switch url.host {
                case "auth":
                    AppState.shared.linkError = nil
                    do { try await Store.shared.finishSignIn(url) } catch { AppState.shared.linkError = error.localizedDescription }
                case "sync": await Store.shared.sync()
                case let page?: if let s = Section(host: page) { AppState.shared.section = s }
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
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Home" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }
}
