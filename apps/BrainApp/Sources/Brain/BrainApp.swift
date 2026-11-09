import BrainCore
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct BrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // the menu bar item is an NSStatusItem (see AppDelegate), so a click can open the panel directly
    var body: some Scene { Settings { EmptyView() } }
}

/// The app object (Info.plist NSPrincipalClass "Brain.BrainApplication"): writes any exception AppKit catches to Brain.log
/// before it crashes, with the reason (which names the window of a layout loop) and the windows on screen.
final class BrainApplication: NSApplication {
    override init() {
        // an exception AppKit catches in its run loop (a layout loop, say) is logged and Brain keeps going, instead of the
        // default for new apps: crash on the spot
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
        super.init()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func reportException(_ e: NSException) {
        let wins = windows.filter(\.isVisible).map { "\(type(of: $0))(\($0.title.isEmpty ? "-" : $0.title)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
        AppDelegate.log("EXCEPTION \(e.name.rawValue): \(e.reason ?? "?") | windows: \(wins.joined(separator: ", "))")
        super.reportException(e)
    }
}

/// Borderless panel that can take keyboard focus without activating a Dock app.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let session = Session()
    var panel: Panel!
    /// The Brain window (sidebar: conversations, knowledge, timers, commands, settings); created on first open.
    let nav = WindowNav()
    var mainWindow: NSWindow?
    /// Notch mode (Settings → Notch): the Dynamic Island-like Brain under the notch.
    var notch: NotchController!
    /// Notch mode as last applied (so a defaults change that isn't about it does nothing).
    var notchWanted = NotchController.enabled
    var hotKey: EventHotKeyRef?
    /// SwiftUI wraps NSApp.delegate in its own object, so the Carbon callback reaches us through this.
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ n: Notification) {
        RenderCheck.runIfAsked()   // `--render`: draw one answer to a PNG and quit (before the one-instance check)
        if RenderCheck.stressing { return }   // `--notch-stress` runs on its own
        // one instance only: a second copy (e.g. the build folder's .app) would fight over the ⌥Space hotkey
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil); return
        }
        Self.shared = self
        // always in the Dock (click opens the Brain window), also with the window closed: no switching between a Dock app
        // and a menu bar app, which AppKit didn't always survive
        NSApp.setActivationPolicy(.regular)
        // an uncaught AppKit exception: its reason into Brain.log (crash reports leave it out), so a crash can be traced
        NSSetUncaughtExceptionHandler { e in
            AppDelegate.log("CRASH \(e.name.rawValue): \(e.reason ?? "?") | \(e.callStackSymbols.prefix(12).joined(separator: " ⏎ "))")
        }
        let room = PanelView.shadowRoom
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 720 + 2 * room, height: 120 + 2 * room), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the SwiftUI panel draws its own rounded shadow; the window's would show square corners
        panel.isMovableByWindowBackground = false   // dragging anywhere would steal text selection; the search bar is the handle
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingView(rootView: PanelView(session: session, close: { [weak self] in self?.hide() },
                                                     brief: { [weak self] in self?.runBrief(notify: false, open: true, mark: false) },
                                                     openWindow: { [weak self] s in self?.openWindow(s) },
                                                     resize: { [weak self] h in self?.setPanelHeight(h) }))
        host.sizingOptions = []   // the window size is set by setPanelHeight, animated
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        session.onFinished = { [weak self] text, failed in self?.notifyAnswer(text, failed: failed) }
        TimerStore.shared.onAnswer = { [weak self] chat, text, failed in self?.notifyTimer(chat, text, failed: failed) }
        TimerStore.shared.onRemind = { [weak self] j in self?.notifyReminder(j) }
        TimerStore.shared.fireDue()   // ones missed while Brain wasn't running
        registerHotKey()
        setUpStatusItem()
        notch = NotchController { [unowned self] m in
            NotchView(model: m, session: session,
                      ask: { [weak self] q in self?.askFromNotch(q) },
                      openWindow: { [weak self] s in self?.notch.collapse(); self?.openWindow(s) },
                      openChat: { [weak self] id in
                          guard let self, let c = HistoryStore.shared.chats.first(where: { $0.id == id }) else { return }
                          notch.collapse(); session.open(c); show()
                      })
        }
        notch.openDone = { [weak self] id in
            guard let self, let c = HistoryStore.shared.chats.first(where: { $0.id == id }) else { self?.show(); return }
            if session.chatId != id { session.open(c) }
            show()
        }
        notch.update()
        // with notch mode on, Brain lives at the notch: no menu bar icon (its menu is on the island's right click)
        statusItem.isVisible = !notch.active
        // only when notch mode really flips, and never inside a layout pass: UserDefaults change all the time (also from AppKit
        // while it lays out), and toggling the status item there sent AppKit into a constraint loop that crashed Brain
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                guard let me = AppDelegate.shared, NotchController.enabled != me.notchWanted else { return }
                me.notchWanted = NotchController.enabled
                me.notch.update()
                let show = !me.notch.active
                if me.statusItem.isVisible != show { me.statusItem.isVisible = show }
            }
        }
        if !pendingURLs.isEmpty { let u = pendingURLs; pendingURLs = []; application(NSApp, open: u) }
        // touch the Google Drive folders from the app itself, so macOS asks once ("files managed by Google Drive")
        // and the helper processes Brain starts inherit the answer instead of being refused silently
        let cloud = NSHomeDirectory() + "/Library/CloudStorage"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: cloud)) ?? [] where d.hasPrefix("GoogleDrive-") && !d.contains("daktela") {
            _ = try? FileManager.default.contentsOfDirectory(atPath: "\(cloud)/\(d)/My Drive")
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // nightly scan runs from here (the app has Full Disk Access; a launchd job may not write to iCloud):
        // check every 30 min, scan once a day after 03:00, or as soon as the Mac wakes if that was missed;
        // the other half-hourly checks import new Fathom meetings
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in Task { @MainActor in AppDelegate.shared?.scanIfDue() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.scanIfDue() }
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    // MARK: menu bar item: click opens the panel, right-click (or ⌃-click) shows the menu

    var statusItem: NSStatusItem!

    func setUpStatusItem() {
        // first launch: sit near the clock rather than next to the notch, where macOS hides icons that don't fit.
        // After that, ⌘-dragging the icon moves it and macOS remembers the spot under this autosave name.
        let key = "NSStatusItem Preferred Position brain"
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(220.0, forKey: key) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "brain"
        guard let b = statusItem.button else { return }
        b.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Brain")
        b.image?.isTemplate = true
        b.toolTip = "Brain — click to search (⌥Space), right-click for options"
        b.target = self
        b.action = #selector(statusClicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showMenu() } else { toggle() }
    }

    func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Ask Brain", action: #selector(menuAsk), keyEquivalent: "").target = self
        m.addItem(withTitle: "Otvoriť okno Brain", action: #selector(menuWindow), keyEquivalent: "").target = self
        m.addItem(withTitle: "Ranný prehľad", action: #selector(menuBrief), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Rescan now", action: #selector(menuRescan), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open notes folder", action: #selector(menuNotes), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open log", action: #selector(menuLog), keyEquivalent: "").target = self
        m.addItem(withTitle: "Prihlásiť iný Claude účet…", action: #selector(menuRelogin), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Ukončiť Brain", action: #selector(quitForReal), keyEquivalent: "q").target = self
        statusItem.menu = m
        statusItem.button?.performClick(nil)   // opens the menu attached for this one click
        statusItem.menu = nil                  // so the next left click opens the panel again
    }

    @objc func menuAsk() { show() }

    // MARK: quitting: closing the window (⌘W, ⌘Q, Dock → Quit) never stops Brain; only "Ukončiť Brain" or logout does

    /// Set by "Ukončiť Brain" (menu bar menu, notch menu): then Brain really quits.
    var reallyQuit = false

    @objc func quitForReal() { reallyQuit = true; NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        if reallyQuit { return .terminateNow }
        // logout, restart or shutdown: the quit event carries a reason; those must go through
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEQuitApplication,
           e.attributeDescriptor(forKeyword: kAEQuitReason) != nil { return .terminateNow }
        // ⌘Q in the Brain window or Quit from the Dock: just close the window, Brain keeps running in the menu bar / notch
        mainWindow?.close()
        hide()
        Self.log("quit turned into closing the window")
        return .terminateCancel
    }
    @objc func menuWindow() { openWindow() }

    // MARK: the Brain window

    func openWindow(_ section: BrainSection? = nil, chat: UUID? = nil) {
        if let section { nav.section = section }
        if let chat { nav.chat = chat }
        if mainWindow == nil {
            let actions = WindowActions(
                continueChat: { [weak self] c in self?.session.open(c); self?.show() },
                newChat: { [weak self] in self?.session.reset(); self?.show() },
                brief: { [weak self] in self?.show(); self?.runBrief(notify: false, open: true, mark: false) },
                rescan: { [weak self] in self?.rescan() },
                login: { [weak self] fresh in self?.show(); if fresh { self?.session.login() } else { self?.session.relogin() } })
            let host = NSHostingController(rootView: MainView(nav: nav, actions: actions))
            host.sceneBridgingOptions = [.toolbars, .title]
            // no sizing from the content: with .minSize the hosting view recomputed the window's limits on every content change
            // (a chat saved when an answer ends) and AppKit crashed in a constraint loop ("updateWindowContentSizeExtrema")
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.title = "Brain"
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 820, height: 520)
            w.setContentSize(NSSize(width: 1040, height: 700))
            if !w.setFrameUsingName("BrainWindow") { w.center() }
            w.setFrameAutosaveName("BrainWindow")
            w.appearance = Look(rawValue: UserDefaults.standard.string(forKey: "look") ?? "auto")?.appearance
            mainWindow = w
        }
        hide()
        NSApp.activate()
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        if let w = mainWindow, w.frame.width < 600 { w.setContentSize(NSSize(width: 1040, height: 700)); w.center() }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow()   // clicking the Dock icon (or opening Brain.app again) shows the window
        return true
    }
    @objc func menuBrief() { runBrief(notify: false, open: true, mark: false) }
    @objc func menuRescan() { rescan() }
    @objc func menuNotes() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Developer/brain/notes")) }
    @objc func menuRelogin() { show(); session.reset(); session.relogin() }
    @objc func menuLog() { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Brain.log")) }

    /// brain://ask?q=… opens the panel and asks, exactly as if typed (handy from Shortcuts, Raycast or scripts); image=<path>
    /// attaches a picture.
    /// brain://chat?id=… opens a saved conversation from the history, to continue it.
    /// URLs that arrive while Brain is still starting (a brain:// link can launch it): handled once the panel exists.
    var pendingURLs: [URL] = []

    func application(_ app: NSApplication, open urls: [URL]) {
        guard panel != nil else { pendingURLs += urls; return }
        for url in urls where url.host == "chat" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            HistoryStore.shared.reload()
            guard let c = HistoryStore.shared.chats.first(where: { $0.id.uuidString == id?.uppercased() }) else { continue }
            show()
            session.open(c)
        }
        // brain://timer?in=<seconds>&q=… (or at=<ISO date>): schedule a follow-up; Brain's schedule tool sends these
        for url in urls where url.host == "timer" || url.host == "timer-cancel" {
            let items = Self.queryItems(url)
            let v = { (k: String) in items.first { $0.name == k }?.value }
            if url.host == "timer-cancel" {   // brain://timer-cancel?id=<uuid> (Brain's timer_cancel tool)
                guard let id = v("id").flatMap(UUID.init(uuidString:)) else { Self.log("timer-cancel without an id"); continue }
                Self.log("timer cancelled: \(TimerStore.shared.cancel([id]).count)")
                continue
            }
            guard let q = v("q"), !q.isEmpty else { continue }
            let wait = v("in").flatMap(Double.init) ?? v("at").flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSinceNow } ?? 0
            guard wait >= 0, wait <= 7 * 86400 else { Self.log("timer refused: \(wait)"); continue }
            let every = v("every").flatMap(Double.init), until = v("until").flatMap { ISO8601DateFormatter().date(from: $0) }
            if every != nil && until == nil { Self.log("recurring timer without an end refused"); continue }
            TimerStore.shared.add(q, in: wait, from: v("from"), approved: v("approved") == "1", remind: v("remind") == "1",
                                  every: every, until: until, id: v("id").flatMap(UUID.init(uuidString:)))
            Self.log("timer set in \(Int(wait))s")
        }
        // brain://window?section=timers (chats, knowledge, timers, commands, settings): open the Brain window
        for url in urls where url.host == "window" {
            openWindow(Self.queryItems(url).first { $0.name == "section" }?.value.flatMap(BrainSection.init(rawValue:)))
        }
        for url in urls where url.host == "stress" {   // brain://stress?seconds=… (testing the panel and notch)
            RenderCheck.stressApp(seconds: Self.queryItems(url).first { $0.name == "seconds" }?.value.flatMap(Double.init) ?? 60)
        }
        // brain://ask?q=…&image=/path/photo.jpg (image may repeat): the pictures go along as attachments
        for url in urls where url.host == "ask" {
            let items = Self.queryItems(url)
            let q = items.first { $0.name == "q" }?.value ?? ""
            show()
            items.filter { $0.name == "image" }.compactMap(\.value).forEach {
                let f = URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                if Attachments.isImage(f) { session.attach(file: f) }
            }
            if !q.isEmpty { session.input = q; session.send() }
        }
    }

    /// The panel grows upwards from its input: its bottom edge stays here while the conversation gets longer.
    var anchorY: CGFloat = 0

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            anchorY = f.minY + f.height * 0.22
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: anchorY - PanelView.shadowRoom))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        Self.log("panel shown")
    }

    func hide() { panel?.orderOut(nil) }

    var shownAt = Date.distantPast

    var panelHeight: CGFloat = 0

    /// Animate the window to the panel's height, keeping its bottom edge (the input) where it is.
    func setPanelHeight(_ h: CGFloat) {
        let total = (h + 2 * PanelView.shadowRoom).rounded()
        guard abs(total - panelHeight) > 0.5 else { return }
        panelHeight = total
        // after SwiftUI's layout pass and without animation: an animated window frame (or one set while SwiftUI lays out)
        // made the hosting view resize the window again inside layout ("updateAnimatedWindowSize") until AppKit threw
        // "more Update Constraints in Window passes than there are views" and Brain crashed when an answer grew the panel
        DispatchQueue.main.async { [self] in
            guard panelHeight == total else { return }   // a newer height is on its way
            let bottom = anchorY > 0 ? anchorY - PanelView.shadowRoom : panel.frame.minY
            panel.setFrame(NSRect(x: panel.frame.minX, y: bottom, width: panel.frame.width, height: total), display: true)
        }
    }

    // dragging the panel by its input moves the anchor with it
    func windowDidMove(_ n: Notification) {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDragged, e.window === panel else { return }
        anchorY = panel.frame.minY + PanelView.shadowRoom
    }

    // click elsewhere → hide, even while Brain is still answering (a notification says when it's done).
    // Ignore the focus shuffle right after opening (the closing menu or the hotkey's app can take key status back for a moment).
    func windowDidResignKey(_ n: Notification) {
        guard (n.object as? NSWindow) === panel, !session.pinned, !session.picking, Date().timeIntervalSince(shownAt) > 0.8 else { return }
        hide()
    }

    /// The answer came while the panel was hidden: say so with its first line; clicking the notification opens the panel.
    /// A timer's answer: always a notification (the panel shows another conversation); clicking it opens that conversation.
    /// From the notch: open the panel, optionally asking right away ("Zmeň návrh: " only fills the field).
    func askFromNotch(_ q: String?) {
        notch.collapse()
        show()
        guard let q else { return }
        if q == "Ranný prehľad" { runBrief(notify: false, open: true, mark: false); return }
        session.input = q
        if !q.hasSuffix(": ") { session.submit(queued: false) }
    }

    func notifyTimer(_ chat: UUID, _ text: String, failed: Bool) {
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        if notch.active { notch.model.show(failed ? "Timer sa nepodaril" : HistoryStore.shared.chats.first { $0.id == chat }?.title ?? "Timer", first, chat: chat) }
        let n = UNMutableNotificationContent()
        n.title = failed ? "⏰ Brain: timer sa nepodaril" : "⏰ Brain: " + (HistoryStore.shared.chats.first { $0.id == chat }?.title.replacingOccurrences(of: "⏰ ", with: "") ?? "timer")
        n.body = String(first.replacingOccurrences(of: #"[*_`#>]|\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression).prefix(180))
        n.sound = .default
        n.userInfo = ["chat": chat.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "timer-\(chat.uuidString)", content: n, trigger: nil))
        Self.log("timer answered")
    }

    /// Query items with "+" read as a space too (form encoding, as older Brain versions and other tools send it).
    static func queryItems(_ url: URL) -> [URLQueryItem] {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        let q = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        c.percentEncodedQuery = q
        return c.queryItems ?? []
    }

    /// A reminder: the text as written, nothing ran. Clicking it opens the panel.
    func notifyReminder(_ j: TimerStore.Job) {
        if notch.active { notch.model.show("Pripomienka", j.prompt) }
        let n = UNMutableNotificationContent()
        n.title = "⏰ Pripomienka"
        n.body = String(j.prompt.prefix(240))
        n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "remind-\(j.id.uuidString)-\(j.runs ?? 0)", content: n, trigger: nil))
        Self.log("reminder shown")
    }

    func notifyAnswer(_ text: String, failed: Bool) {
        if notch.active {   // the island: a checkmark beside the notch (instead of a system notification); click opens the chat
            if !text.isEmpty { notch.model.finished(session.chatId, failed: failed) }
            return
        }
        guard !panel.isVisible, !text.isEmpty else { return }
        let firstLine = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let plain = firstLine.replacingOccurrences(of: #"[*_`#>]|\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        let n = UNMutableNotificationContent()
        n.title = failed ? "Brain: niečo sa nepodarilo" : text.contains("proposal") || text.localizedCaseInsensitiveContains("potvrd") ? "Brain čaká na tvoje potvrdenie" : "Brain má hotovo"
        n.body = String(plain.prefix(180))
        n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "answer-\(Date().timeIntervalSince1970)", content: n, trigger: nil))
        Self.log("answer notified")
    }

    var scanTimer: Timer?

    func scanIfDue() {
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/Developer/brain/data/last-scan.json")
        var last = Date.distantPast
        if let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let at = j["at"] as? String, let date = ISO8601DateFormatter.withFraction.date(from: at) ?? ISO8601DateFormatter().date(from: at) { last = date }
        let hour = Calendar.current.component(.hour, from: Date())
        if Date().timeIntervalSince(last) > 20 * 3600 && hour >= 3 { Self.log("nightly scan"); rescan() }
        else { fathomImport() }   // the nightly scan imports Fathom too
        briefIfDue()
    }

    var fathomRunning = false

    /// Every 30 min: new Fathom recordings (both accounts) become meeting notes, their tasks go to Todoist/Reminders.
    /// A notification says what came in; clicking it opens the panel.
    func fathomImport() {
        guard !fathomRunning else { return }
        fathomRunning = true
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
        p.arguments = [NSHomeDirectory() + "/Developer/brain/src/cli.js", "fathom"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let meetings = j?["new_meetings"] as? [String] ?? []
            let tasks = (j?["tasks"] as? [String: Any])?["tasks"] as? [String] ?? []
            DispatchQueue.main.async {
                guard let me = AppDelegate.shared else { return }
                me.fathomRunning = false
                if j == nil { AppDelegate.log("fathom import failed: \(String(decoding: data.prefix(200), as: UTF8.self))"); return }
                guard !meetings.isEmpty else { return }
                AppDelegate.log("fathom: \(meetings.count) new, \(tasks.count) tasks")
                let n = UNMutableNotificationContent()
                n.title = meetings.count == 1 ? "Nový meeting z Fathomu" : "\(meetings.count) nové meetingy z Fathomu"
                let names = meetings.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
                n.body = names.joined(separator: ", ") + (tasks.isEmpty ? "" : " · úlohy: \(tasks.count)")
                n.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fathom-\(Date().timeIntervalSince1970)", content: n, trigger: nil))
            }
        }
        do { try p.run() } catch { fathomRunning = false }
    }

    // MARK: morning brief — once a day from 7:00 (or at the first wake/login after it): notification, click opens it

    var lastBriefDay: String {
        get { UserDefaults.standard.string(forKey: "lastBriefDay") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastBriefDay") }
    }

    func briefIfDue() {
        let day = ISO8601DateFormatter.dayOnly.string(from: Date())
        guard Calendar.current.component(.hour, from: Date()) >= 7, lastBriefDay != day else { return }
        lastBriefDay = day
        runBrief(notify: true, open: false, mark: true)
    }

    /// Runs `brain brief --json` (built from the data, no model) and shows it in the panel and/or as a notification.
    func runBrief(notify: Bool, open: Bool, mark: Bool) {
        if open { session.reset(); session.status = "Skladám ranný prehľad: kalendár, úlohy, meetingy, WhatsApp, trhy…" }
        let fromPanel = panel.isVisible   // started from the panel's button: if it gets hidden meanwhile, notify instead of popping up
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
        p.arguments = [NSHomeDirectory() + "/Developer/brain/src/cli.js", "brief", "--json"] + (mark ? [] : ["--peek"])
        p.standardOutput = out
        p.standardError = err
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in data.append(h.availableData) }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            data.append(out.fileHandleForReading.readDataToEndOfFile())
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile().prefix(1500), as: UTF8.self)
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let md = j["markdown"] as? String else {
                let head = String(decoding: data.prefix(200), as: UTF8.self)
                DispatchQueue.main.async {
                    AppDelegate.log("brief failed (exit \(proc.terminationStatus)): \(head) | \(errText)")
                    if open { AppDelegate.shared?.session.status = nil; AppDelegate.shared?.session.showBrief("Ranný prehľad sa nepodarilo poskladať. Pozri log (pravý klik na ikonu → Open log).") }
                }
                return
            }
            let c = j["counts"] as? [String: Int] ?? [:]
            DispatchQueue.main.async {
                guard let me = AppDelegate.shared else { return }
                me.session.showBrief(md)
                if open && fromPanel && !me.panel.isVisible { me.notifyBrief(c) }
                else if open { me.show() }
                if notify { me.notifyBrief(c) }
                AppDelegate.log("brief shown \(c): \(md.prefix(600).replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        try? p.run()
    }

    func notifyBrief(_ c: [String: Int]) {
        var parts: [String] = []
        if let n = c["celebrations"], n > 0 { parts.append("🎉 \(n) \(n == 1 ? "oslava" : "oslavy")") }
        if let n = c["overdue"], n > 0 { parts.append("\(n) po termíne") }
        parts.append("\(c["today"] ?? 0) dnes")
        if let n = c["meetings"], n > 0 { parts.append("\(n) \(n == 1 ? "nový meeting" : "nové meetingy")") }
        if let n = c["waiting"], n > 0 { parts.append("\(n) čaká na odpoveď") }
        if let n = c["unprotected"], n > 0 { parts.append("⚠️ \(n) \(n == 1 ? "pozícia" : "pozície") bez trvalého stop lossu") }
        if let n = c["movers"], n > 0 { parts.append("📈 \(n) \(n == 1 ? "veľký pohyb" : "veľké pohyby") na trhu") }
        let n = UNMutableNotificationContent()
        n.title = "Ranný prehľad"
        n.body = parts.joined(separator: " · ")
        n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brief-\(lastBriefDay)", content: n, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let chat = r.notification.request.content.userInfo["chat"] as? String
        DispatchQueue.main.async {
            guard let app = AppDelegate.shared else { return }
            app.show()
            if let chat, let c = HistoryStore.shared.chats.first(where: { $0.id.uuidString == chat }) { app.session.open(c) }
        }
        done()
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func rescan() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
        p.arguments = [NSHomeDirectory() + "/Developer/brain/src/cli.js", "scan"]
        p.standardOutput = FileHandle(forWritingAtPath: NSHomeDirectory() + "/Library/Logs/brain-scan.log") ?? FileHandle.nullDevice
        try? p.run()
    }

    /// ⌥Space, system-wide, via Carbon (needs no Accessibility permission).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.log("hotkey pressed"); AppDelegate.shared?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4252_4E31), id: 1)   // "BRN1"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        Self.log("hotkey ⌥Space register status \(status)")
    }

    static func log(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Brain.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f }()
    static let withFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
