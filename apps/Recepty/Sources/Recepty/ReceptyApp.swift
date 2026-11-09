import AppKit
import ReceptyCore
import SwiftUI

@main
struct ReceptyApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate

    init() { Demo.applyArguments(); Snapshot.runIfAsked() }

    var body: some Scene {
        Window("Recepty", id: "main") { ContentView(model: .shared) }
            .defaultSize(width: 1240, height: 820)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Nový recept z odkazu alebo textu…") { AppModel.shared.sheet = .importer }.keyboardShortcut("n")
                    Button("Prázdny recept…") { AppModel.shared.sheet = .edit(Recipe()) }.keyboardShortcut("n", modifiers: [.command, .shift])
                }
                CommandMenu("Recepty") {
                    Button("Všetky recepty") { AppModel.shared.page = .all; AppModel.shared.path = [] }.keyboardShortcut("1")
                    Button("Jedálniček") { AppModel.shared.page = .plan }.keyboardShortcut("2")
                    Button("Denník") { AppModel.shared.page = .log }.keyboardShortcut("3")
                    Button("Nákup") { AppModel.shared.page = .shopping }.keyboardShortcut("4")
                    Divider()
                    Button("Obnoviť") { AppModel.shared.reload() }.keyboardShortcut("r")
                }
            }

        // Cook mode, one window per recipe; app links never open it.
        WindowGroup("Varenie", id: "cook", for: Int64.self) { $id in
            if let id, let r = AppModel.shared.recipe(id) { CookView(recipe: r) }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
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

    /// recepty://library, new (import), plan, log, shopping, recipe/<id>, cook/<id>.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "recepty" {
            Task { @MainActor in
                let m = AppModel.shared
                m.reload()
                let id = Int64(url.lastPathComponent)
                switch url.host {
                case "new", "import": m.sheet = .importer
                case "plan": m.page = .plan
                case "log": m.page = .log
                case "shopping": m.page = .shopping
                case "recipe": if let id { m.open(id) }
                case "cook": if let id { m.open(id); Delegate.showWindow(); m.cook(m.recipe(id) ?? Recipe()); return }
                default: m.page = .all; m.path = []
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
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Recepty" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            AppModel.shared.openMain?()
        }
    }
}
