import AppKit
import ServiceManagement
import SwiftUI

@main
struct MarketBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model, openBrief: delegate.showBrief, openSettings: delegate.showSettings)
        } label: {
            MenuLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
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

    let model = Model()
    var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        // one instance only: a second copy (e.g. the build folder's .app) would fight over the hotkey / the one live-price stream
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil); return
        }
        Notifier.shared.setUp()
        Notifier.shared.onOpenBrief = { [weak self] in self?.showBrief() }
        // open at login by default, once; the Settings toggle can turn it off
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        model.start()
    }

    /// marketbar://brief, marketbar://brief-now, marketbar://settings
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "brief": showBrief()
            case "brief-now": Task { await model.makeBrief(notify: true); showBrief() }
            case "settings": showSettings()
            default: break
            }
        }
    }

    func showBrief() { show("brief", title: "Market brief", BriefView(model: model)) }
    func showSettings() { show("settings", title: "MarketBar Settings", SettingsView(model: model)) }

    /// Plain NSWindows, so they open from notifications and the menu without a SwiftUI scene being on screen.
    func show<V: View>(_ id: String, title: String, _ view: V) {
        let w = windows[id] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = title
            w.isReleasedWhenClosed = false
            w.center()
            windows[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
