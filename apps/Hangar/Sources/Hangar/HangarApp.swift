import AppKit
import SwiftUI

/// One of my apps: found in ~/Applications or /Applications by its bundle id (com.lockedin.*), so a new app in the series
/// shows up here by itself once it's installed.
struct MyApp: Identifiable, Equatable {
    let id: String          // bundle id
    let name: String
    let url: URL
    /// Loaded once: asking NSWorkspace for the icon on every redraw makes a new image each time and the tiles flicker.
    let icon: NSImage
    var running: Bool

    static func == (a: MyApp, b: MyApp) -> Bool { a.id == b.id && a.running == b.running && a.name == b.name }

    /// What "open" means for an app that lives in the menu bar (it has no window to bring forward), plus its other actions.
    var actions: [Action] { Self.known[id] ?? [] }
    var subtitle: String? { Self.subtitles[id] }

    struct Action { let title: String; let symbol: String; let url: String }

    static let known: [String: [Action]] = [
        "com.lockedin.brain": [Action(title: "Otvoriť panel", symbol: "sparkles", url: "brain://ask")],
        "com.lockedin.marketbar": [Action(title: "Market brief", symbol: "doc.text", url: "marketbar://brief"),
                                   Action(title: "Nový brief teraz", symbol: "arrow.trianglehead.2.clockwise", url: "marketbar://brief-now"),
                                   Action(title: "Nastavenia", symbol: "gearshape", url: "marketbar://settings")],
        "com.lockedin.courier": [Action(title: "Doručená pošta", symbol: "tray", url: "courier://inbox"),
                                 Action(title: "Nová správa", symbol: "square.and.pencil", url: "courier://compose")],
        "com.lockedin.fitness": [Action(title: "Prehľad", symbol: "chart.bar.xaxis", url: "fitness://overview"),
                                 Action(title: "Obnoviť dáta", symbol: "arrow.clockwise", url: "fitness://refresh")],
        "com.lockedin.meetings": [Action(title: "Najbližší meeting", symbol: "calendar", url: "meetings://next"),
                                  Action(title: "Nahrávky", symbol: "waveform", url: "meetings://recordings")],
        "com.lockedin.faktury": [Action(title: "Nová faktúra", symbol: "square.and.pencil", url: "faktury://new"),
                                 Action(title: "Neuhradené", symbol: "clock", url: "faktury://unpaid")],
        "com.lockedin.financie": [Action(title: "Nový výdavok", symbol: "minus.circle", url: "financie://new"),
                                  Action(title: "Nový príjem", symbol: "plus.circle", url: "financie://new-income"),
                                  Action(title: "Čaká na potvrdenie", symbol: "clock", url: "financie://waiting")],
        "com.lockedin.recepty": [Action(title: "Nový recept", symbol: "plus.circle", url: "recepty://new"),
                                 Action(title: "Jedálniček", symbol: "calendar", url: "recepty://plan"),
                                 Action(title: "Nákup", symbol: "cart", url: "recepty://shopping")],
        "com.lockedin.home": [Action(title: "Dnes", symbol: "sun.max", url: "home://today"),
                              Action(title: "Nákup", symbol: "cart", url: "home://shopping"),
                              Action(title: "Úlohy", symbol: "checklist", url: "home://tasks")],
        "com.lockedin.ludia": [Action(title: "Ozvi sa", symbol: "bell.badge", url: "ludia://due"),
                               Action(title: "Oslavy", symbol: "gift", url: "ludia://celebrations"),
                               Action(title: "Sľuby", symbol: "hand.raised", url: "ludia://promises")],
        "com.lockedin.herald": [Action(title: "Čaká na teba", symbol: "arrowshape.turn.up.left", url: "herald://reply"),
                                Action(title: "Prospekti", symbol: "person.crop.circle.badge.plus", url: "herald://prospects"),
                                Action(title: "Čakajúce pozvánky", symbol: "hourglass", url: "herald://pending")],
        "com.lockedin.obchody": [Action(title: "Dnes", symbol: "sun.max", url: "obchody://today"),
                             Action(title: "Pipeline 10T", symbol: "rectangle.split.3x1", url: "obchody://pipeline/10t"),
                             Action(title: "Pipeline Kudosky", symbol: "rectangle.split.3x1", url: "obchody://pipeline/kudosky")],
        "com.lockedin.scout": [Action(title: "Firmy", symbol: "building.2", url: "scout://companies"),
                               Action(title: "Ľudia", symbol: "person.2", url: "scout://people"),
                               Action(title: "Nekontaktovať", symbol: "hand.raised", url: "scout://blocked")],
    ]
    static let subtitles: [String: String] = ["com.lockedin.brain": "Asistent a pamäť", "com.lockedin.marketbar": "Trhy a Alpaca",
                                              "com.lockedin.courier": "Pošta a projekty", "com.lockedin.fitness": "Tréning a strava",
                                              "com.lockedin.meetings": "Príprava a nahrávky",
                                              "com.lockedin.faktury": "Faktúry a úhrady",
                                              "com.lockedin.financie": "Osobné a firemné financie",
                                              "com.lockedin.recepty": "Recepty, výživa a jedálniček",
                                              "com.lockedin.ludia": "Osobné CRM",
                                              "com.lockedin.home": "Úlohy a nákup domácnosti",
                                              "com.lockedin.herald": "LinkedIn a projekty",
                                              "com.lockedin.obchody": "10T a Kudosky: klienti a obchody",
                                              "com.lockedin.scout": "E-maily firiem"]
}

@MainActor
final class Apps: ObservableObject {
    static let prefix = "com.lockedin."
    @Published var list: [MyApp] = []
    /// Apps Hangar is starting right now (shows a spinner on the tile until they're ready).
    @Published var launching: Set<String> = []
    /// Unread counts the apps publish (Courier: unread mail from people), shown as a red badge on the tile like in the Dock.
    @Published var badges: [String: Int] = [:]
    static let badgeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.lockedin/badges")

    var runningCount: Int { list.filter(\.running).count }

    init() {
        reload()
        let c = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshRunning() } }
        }
        // an app announces a new count ("com.lockedin.badge", object: its bundle id); the file has the same number for later
        DistributedNotificationCenter.default().addObserver(forName: .init("com.lockedin.badge"), object: nil, queue: .main) { [weak self] n in
            guard let id = n.object as? String, let count = n.userInfo?["count"] as? Int else { return }
            Task { @MainActor in self?.badges[id] = count }
        }
    }

    func loadBadges() {
        var out: [String: Int] = [:]
        for a in list {
            if let s = try? String(contentsOf: Self.badgeDir.appendingPathComponent(a.id), encoding: .utf8),
               let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { out[a.id] = n }
        }
        badges = out
    }

    func reload() {
        let fm = FileManager.default
        var found: [String: MyApp] = [:]
        for dir in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".app") {
                let url = dir.appendingPathComponent(name)
                guard let b = Bundle(url: url), let id = b.bundleIdentifier, id.hasPrefix(Self.prefix), id != Bundle.main.bundleIdentifier,
                      found[id] == nil else { continue }
                let title = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                found[id] = MyApp(id: id, name: title, url: url, icon: NSWorkspace.shared.icon(forFile: url.path), running: false)
            }
        }
        list = arranged(Array(found.values))
        refreshRunning()
        loadBadges()
    }

    // MARK: order

    /// Your own order (dragged in the window), kept in UserDefaults; apps you haven't placed yet go after it, by name.
    static let orderKey = "order"
    var order: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.orderKey) }
    }

    func arranged(_ apps: [MyApp]) -> [MyApp] {
        let pos = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return apps.sorted { a, b in
            switch (pos[a.id], pos[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Drops `id` onto `target`'s place (before it when coming from later in the list, after it when coming from earlier).
    func move(_ id: String, onto target: String) {
        guard id != target, let from = list.firstIndex(where: { $0.id == id }), let to = list.firstIndex(where: { $0.id == target }) else { return }
        let a = list.remove(at: from)
        list.insert(a, at: to)
        order = list.map(\.id)
    }

    var customOrder: Bool { !order.isEmpty }

    func sortByName() {
        order = []
        list = arranged(list)
    }

    func refreshRunning() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for i in list.indices where list[i].running != ids.contains(list[i].id) { list[i].running.toggle() }   // only real changes redraw
    }

    /// Opens the app: its first action URL (menu bar apps show their panel or window), else launches / brings it forward.
    ///
    /// An app that isn't running is started first and gets the URL only once it has finished launching. Sent together with
    /// the launch, the URL arrives before the app has set up its windows and status item (Courier passes it on through a
    /// notification nobody listens to yet), so nothing would open.
    func open(_ a: MyApp, action: String? = nil) {
        let url = (action ?? a.actions.first?.url).flatMap(URL.init(string:))
        let ready = NSRunningApplication.runningApplications(withBundleIdentifier: a.id).contains { $0.isFinishedLaunching && !$0.isTerminated }
        if ready {
            if let url { send(url, to: a) } else { launch(a) }   // launching a running app reopens it: shows its window
            return
        }
        guard !launching.contains(a.id) else { return }
        launching.insert(a.id)
        Task { @MainActor in
            defer { launching.remove(a.id) }
            guard let app = try? await NSWorkspace.shared.openApplication(at: a.url, configuration: Self.config) else { return }
            for _ in 0..<100 where !app.isFinishedLaunching { try? await Task.sleep(for: .milliseconds(100)) }
            guard let url else { return }
            try? await Task.sleep(for: .milliseconds(700))   // let its scenes and URL observers come up
            send(url, to: a)
        }
    }

    private static var config: NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        return c
    }

    private func send(_ url: URL, to a: MyApp) {
        NSWorkspace.shared.open([url], withApplicationAt: a.url, configuration: Self.config, completionHandler: nil)
    }

    private func launch(_ a: MyApp) {
        NSWorkspace.shared.openApplication(at: a.url, configuration: Self.config, completionHandler: nil)
    }

    func quit(_ a: MyApp) { NSRunningApplication.runningApplications(withBundleIdentifier: a.id).forEach { $0.terminate() } }

    func restart(_ a: MyApp) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: a.id)
        apps.forEach { $0.terminate() }
        launching.insert(a.id)
        Task { @MainActor in
            for _ in 0..<50 where apps.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(100)) }
            launching.remove(a.id)
            open(a)
        }
    }

    func reveal(_ a: MyApp) { NSWorkspace.shared.activateFileViewerSelecting([a.url]) }
}

// MARK: Window

struct HangarView: View {
    @ObservedObject var apps: Apps
    let columns = [GridItem(.adaptive(minimum: 86, maximum: 100), spacing: 6)]
    @State private var dropTarget: String?

    var body: some View {
        Group {
            if apps.list.isEmpty {
                ContentUnavailableView {
                    Label("Žiadne appky", systemImage: "square.dashed")
                } description: {
                    Text("Appky s bundle id „\(Apps.prefix)…“ v ~/Applications alebo /Applications sa tu zobrazia samé.")
                } actions: {
                    Button("Znova načítať") { apps.reload() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(apps.list) { a in
                            Tile(app: a, apps: apps, launching: apps.launching.contains(a.id), badge: apps.badges[a.id] ?? 0)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: dropTarget == a.id ? 2 : 0))
                                .draggable(a.id) { Image(nsImage: a.icon).resizable().frame(width: 48, height: 48) }
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let id = ids.first else { return false }
                                    withAnimation(.snappy(duration: 0.2)) { apps.move(id, onto: a.id) }
                                    return true
                                } isTargeted: { on in dropTarget = on ? a.id : (dropTarget == a.id ? nil : dropTarget) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 300, minHeight: 200)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Zoradiť podľa abecedy") { withAnimation(.snappy(duration: 0.2)) { apps.sortByName() } }.disabled(!apps.customOrder)
                } label: { Label("Poradie", systemImage: "arrow.up.arrow.down") }
                .help("Appky presunieš ťahaním. Tu ich vrátiš podľa abecedy.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { apps.reload() } label: { Label("Znova načítať", systemImage: "arrow.clockwise") }
                    .help("Znova načítať zoznam appiek (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    var subtitle: String {
        let n = apps.list.count, r = apps.runningCount
        guard n > 0 else { return "" }
        return r == 0 ? "\(n) appky" : "\(n) appky · \(r) beží"
    }
}

/// An app as macOS shows apps everywhere else: the icon, its name under it, and a Dock-style dot when it's running.
struct Tile: View {
    let app: MyApp
    @ObservedObject var apps: Apps
    let launching: Bool
    let badge: Int
    @State private var hover = false

    var body: some View {
        Button { apps.open(app) } label: {
            VStack(spacing: 4) {
                Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 50, height: 50)
                    .overlay {
                        if launching { ProgressView().controlSize(.small) }
                    }
                    .opacity(launching ? 0.6 : 1)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { Badge(count: badge).offset(x: 8, y: -6) }
                    }
                Text(app.name).font(.callout).lineLimit(1).truncationMode(.tail)
                if let s = app.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Circle().fill(.primary.opacity(app.running ? 0.6 : 0)).frame(width: 4, height: 4)   // as under Dock icons
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10).padding(.bottom, 6).padding(.horizontal, 6)
            .background(.fill.quaternary.opacity(hover ? 1 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(PressStyle())
        .focusEffectDisabled()   // else the first tile gets the window's focus and a thick ring around it
        .onHover { hover = $0 }   // no animation: animated hover over the grid flickered
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue([app.subtitle, app.running ? "beží" : "nebeží", badge > 0 ? (app.id == "com.lockedin.ludia" ? "\(badge) čaká, kým sa ozveš" : "\(badge) neprečítaných") : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(app.running ? "Otvorí appku" : "Spustí appku")
        .contextMenu { menu }
    }

    var help: String {
        let first = app.actions.first?.title
        if launching { return "Spúšťa sa…" }
        if app.running { return first ?? "Otvoriť" }
        return first.map { "Spustiť a \($0.lowercased())" } ?? "Spustiť"
    }

    @ViewBuilder var menu: some View {
        if app.actions.isEmpty {
            Button { apps.open(app) } label: { Label(app.running ? "Otvoriť" : "Spustiť", systemImage: "arrow.up.forward.app") }
        }
        ForEach(app.actions, id: \.url) { act in
            Button { apps.open(app, action: act.url) } label: { Label(act.title, systemImage: act.symbol) }
        }
        Divider()
        if app.running {
            Button { apps.restart(app) } label: { Label("Reštartovať", systemImage: "arrow.clockwise") }
            Button { apps.quit(app) } label: { Label("Ukončiť", systemImage: "xmark.circle") }
            Divider()
        }
        Button { apps.reveal(app) } label: { Label("Ukázať vo Finderi", systemImage: "folder") }
    }
}

/// The red count in the icon's corner, as the Dock draws it.
struct Badge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 6 : 0)
            .frame(minWidth: 22, minHeight: 22)
            .background(Color(red: 1.0, green: 0.23, blue: 0.19), in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// Plain look, but with the slight press-down that tells you the click registered.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

@main
struct HangarApp: App {
    @StateObject var apps = Apps()
    @NSApplicationDelegateAdaptor var delegate: Delegate

    var body: some Scene {
        Window("Hangar", id: "main") { HangarView(apps: apps).onAppear { RenderCheck.runIfAsked(apps) } }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 560, height: 400)
            .commands { CommandGroup(replacing: .newItem) {} }
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

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { app.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}
