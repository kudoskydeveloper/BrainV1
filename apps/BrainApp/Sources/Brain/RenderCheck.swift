import AppKit
import SwiftUI

/// `Brain --render <answer.md> <out.png> [dark]`: draws one answer as the panel shows it into a PNG and quits, for checking
/// how answers look without opening the panel. Uses a real (off-screen) window, so the NSTextView renders too.
@MainActor
enum RenderCheck {
    static func runIfAsked() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--window-snapshot"), i + 1 < a.count { windowSnapshot(URL(fileURLWithPath: a[i + 1])) }
        if let i = a.firstIndex(of: "--notch-stress") { notchStress(seconds: i + 1 < a.count ? Double(a[i + 1]) ?? 60 : 60, only: a.firstIndex(of: "--only").map { a[$0 + 1] }); return }
        guard let i = a.firstIndex(of: "--render"), i + 2 < a.count, let md = try? String(contentsOfFile: a[i + 1], encoding: .utf8) else { return }
        let dark = a.count > i + 3 && a[i + 3] == "dark"
        let q = a.count > i + 4 ? a[i + 4] : "Otázka"
        let view = VStack(alignment: .leading, spacing: 18) {
            Turn(message: Message(mine: true, text: q))
            Turn(message: Message(mine: false, text: md))
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(width: 720)
        .background(dark ? Color(white: 0.16) : Color(white: 0.97))
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[i + 2]))
        print("ok \(Int(size.width))×\(Int(size.height))")
        exit(0)
    }

    /// `Brain --window-snapshot <dir>`: every section of the Brain window to PNG (light and dark), from a real off-screen
    /// window, so lists and forms render too. For checking the design without screen recording permission.
    static func windowSnapshot(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let none = WindowActions(continueChat: { _ in }, newChat: {}, brief: {}, rescan: {}, login: { _ in })
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1040, height: 700),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        for dark in [false, true] {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for s in BrainSection.allCases {
                let nav = WindowNav()
                nav.section = s
                if s == .chats { nav.chat = HistoryStore.shared.chats.first?.id }
                let host = NSHostingController(rootView: MainView(nav: nav, actions: none).environment(\.snapshot, true))
                host.sceneBridgingOptions = [.toolbars, .title]
                w.contentViewController = host
                w.setContentSize(NSSize(width: 1040, height: 700))
                w.orderFrontRegardless()
                for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }   // let lists and async loads settle
                guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(s.rawValue)\(dark ? "-dark" : "").png"))
                print("ok \(s.rawValue)\(dark ? " dark" : "")")
            }
        }
        // the panel: empty, and with a sample conversation (steps, a proposal, options, a checklist)
        for (name, sample) in [("panel-empty", false), ("panel-chat", true), ("panel-photo", false)] {
            let session = Session()
            if name == "panel-photo" {   // a picture in the composer and one sent with a question
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 400, height: 300).fill()
                NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 100, y: 50, width: 200, height: 200)).fill()
                NSGraphicsContext.restoreGraphicsState()
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("brain-snapshot-photo.png")
                if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: u)) != nil {
                    session.attachments = [u]
                    session.chatTitle = "Čo je na tejto fotke?"
                    session.messages = [Message(mine: true, text: "čo to je a koľko to má kalórií", images: [u]),
                                        Message(mine: false, text: "Na fotke je **tanier s ryžou** (~200 g): asi **260 kcal**.")]
                }
            }
            if sample {
                session.chatTitle = "Pošta od Stely a nákup"
                session.messages = [
                    Message(mine: true, text: "pozri poštu a navrhni čo archivovať, a pošli Jane že idem domov"),
                    Message(mine: false, text: "Na archiváciu sú tieto, vyber:\n\n- [ ] Newsletter Alza (3 správy)\n- [ ] Faktúra O2 za október\n- [x] Notifikácie z GitHubu (12)\n\nSpráva pre Stelu je pripravená.\n\nMožnosti: Archivuj aj staršie | Len tieto | Nič",
                            steps: ["Pozerám poštu v Courieri…", "Pripravujem správu na WhatsApp…"],
                            proposals: [Proposal(id: "brain_test", summary: "WhatsApp to Jana Nová:\n\"idem domov 🙂\""),
                                        Proposal(id: "brain_t2", summary: "Todoist (Kudosky): Presunúť 10 úloh na dnes až pondelok\n· tasks: 10 (2026-11-07 ×5, 2026-11-08 ×4, 2026-11-09 ×1)"),
                                        Proposal(id: "brain_t3", summary: "courier.save_attachment({\"message_id\":7889,\"index\":0})")]),

                ]
                session.marked = ["brain_t2": true]
            }
            let w2 = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 824, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            w2.isOpaque = false; w2.backgroundColor = .clear
            w2.contentView = NSHostingView(rootView: PanelView(session: session, close: {}, brief: {}, openWindow: { _ in }, resize: { _ in })
                .background(Color(white: 0.55)))
            w2.orderFrontRegardless()
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            if let v = w2.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                print("ok \(name)")
            }
        }
        // the notch island: collapsed while working, open (menu), open with a proposal, and a notification
        let states: [(String, (NotchModel, Session) -> Void)] = [
            ("notch-working", { _, s in s.running = true; s.status = "Pozerám poštu v Courieri…"
                s.messages = [Message(mine: true, text: "pošta"), Message(mine: false, text: "", steps: ["Pozerám poštu v Courieri…"])] }),
            ("notch-done", { m, _ in m.done = (UUID(), false) }),
            ("notch-menu", { m, _ in m.expanded = true }),
            ("notch-proposal", { m, s in m.expanded = true; s.chatTitle = "Správa pre Stelu"
                s.messages = [Message(mine: true, text: "napíš Jane"), Message(mine: false, text: "Pripravené.", proposals: [Proposal(id: "b1", summary: "WhatsApp to Jana Nová:\n\"idem domov 🙂\"")])] }),
            ("notch-flash", { m, _ in m.flash = ("Brain má hotovo", "V pošte sú 3 nové konverzácie od ľudí, odpísať treba Petrovi Hudecovi.", nil) }),
        ]
        for (name, setup) in states {
            let m = NotchModel(), s = Session()
            m.notch = CGSize(width: 179, height: 32)
            setup(m, s)
            let v = NotchView(model: m, session: s, ask: { _ in }, openWindow: { _ in }, openChat: { _ in })
                .background(alignment: .top) { Color(white: 0.93).frame(height: 32) }   // the menu bar
                .background(Color(white: 0.75))
            let w3 = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: NotchView.size.width, height: NotchView.size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            w3.contentView = NSHostingView(rootView: v)
            w3.orderFrontRegardless()
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            if let c = w3.contentView, let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds) {
                c.cacheDisplay(in: c.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                print("ok \(name)")
            }
        }
        exit(0)
    }

    /// Set while `--notch-stress` runs: the app skips its normal start (and timers never fire from this process).
    static var stressing = false
    static var stressPanel: NSPanel?

    /// `Brain --notch-stress [seconds] [--only <steps>]`: the notch on the real screen, cycled fast through its states (working,
    /// steps, done checkmark coming and going, proposal, queue, open, notification) with a fake session, to reproduce
    /// layout crashes. Prints a line per cycle; exits 0 when the time is up.
    static func notchStress(seconds: Double, only: String?) {
        stressing = true
        let session = Session()
        let controller = NotchController { m in NotchView(model: m, session: session, ask: { _ in }, openWindow: { _ in }, openChat: { _ in }) }
        controller.startForTest()
        let m = controller.model
        // the panel too, on screen, sharing the session (as in the app); unless --no-panel
        if !CommandLine.arguments.contains("--no-panel") {
            let room = PanelView.shadowRoom
            let p = Panel(contentRect: NSRect(x: 300, y: 120, width: 720 + 2 * room, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .floating
            let host = NSHostingView(rootView: PanelView(session: session, close: {}, brief: {}, openWindow: { _ in }, resize: { [weak p] h in
                guard let p else { return }
                p.setFrame(NSRect(x: p.frame.minX, y: 120, width: p.frame.width, height: (h + 2 * room).rounded()), display: true, animate: false)
            }))
            host.sizingOptions = []
            p.contentView = host
            p.orderFrontRegardless()
            stressPanel = p
        }
        let steps: [(String, () -> Void)] = [
            ("run", { session.running = true; session.status = "Pozerám poštu…"
                session.messages = [Message(mine: true, text: "q"), Message(mine: false, text: "", steps: ["Pozerám poštu…"])] }),
            ("step", { var x = session.messages[1]; x.steps.append("Krok \(Int.random(in: 1...99))…"); session.messages[1] = x; session.status = x.steps.last }),
            ("text", { var x = session.messages[1]; x.text += ["Odpoveď \(Int.random(in: 1...9)). ", "\n\n| a | b |\n|---|---|\n| 1 | 2 |\n",
                "\n\n- [ ] lístky\n- [ ] kalendár\n", "\n\nMožnosti: Áno | Nie", "\n\n**Tučné** a [odkaz](https://example.com)"].randomElement()!; session.messages[1] = x }),
            ("done", { session.running = false; session.status = nil; m.finished(UUID(), failed: Bool.random()) }),
            ("undone", { withAnimation(NotchModel.closing) { m.done = nil } }),
            ("proposal", { var x = session.messages[1]; x.proposals = [Proposal(id: "p\(Int.random(in: 1...999))", summary: "WhatsApp to X: ahoj")]; session.messages[1] = x }),
            ("decide", { if let p = session.messages[1].proposals.first { session.decided[p.id] = true } }),
            ("queue", { session.queue = session.queue.isEmpty ? ["ďalšia otázka"] : [] }),
            ("open", { withAnimation(NotchModel.opening) { m.expanded = true } }),
            ("close", { withAnimation(NotchModel.closing) { m.expanded = false } }),
            ("flash", { m.show("Brain má hotovo", "Hotová odpoveď \(Int.random(in: 1...9))") }),
            ("reset", { session.running = false; session.status = nil; session.messages = []; session.queue = []; session.decided = [:] }),
        ]
        let allowed = only.map { Set($0.split(separator: ",").map(String.init)) }
        let pool = steps.filter { allowed?.contains($0.0) ?? true }
        let end = Date().addingTimeInterval(seconds)
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.23, repeats: true) { t in
            MainActor.assumeIsolated {
                if Date() > end { print("ok \(n) steps"); exit(0) }
                if session.messages.count < 2 { pool.first { $0.0 == "run" }?.1() ?? steps[0].1() }
                let s = pool.randomElement()!
                s.1(); n += 1
                if n % 25 == 0 { print("step \(n): \(s.0)"); fflush(stdout) }
            }
        }
    }

    /// brain://stress?seconds=120: the same state cycling inside the running app, with its real panel (shown, hidden,
    /// resized), notch, Brain window and hidden status item. No Claude is asked; the panel's conversation is cleared after.
    static func stressApp(seconds: Double) {
        guard let app = AppDelegate.shared else { return }
        let session = app.session, m = app.notch.model
        session.reset()
        var saved = Set<UUID>()
        let steps: [(String, () -> Void)] = [
            ("run", { session.running = true; session.status = "Pozerám poštu…"
                session.messages = [Message(mine: true, text: "test"), Message(mine: false, text: "", steps: ["Pozerám poštu…"])] }),
            ("step", { guard session.messages.count > 1 else { return }; var x = session.messages[1]; x.steps.append("Krok \(Int.random(in: 1...99))…"); session.messages[1] = x; session.status = x.steps.last }),
            ("text", { guard session.messages.count > 1 else { return }; var x = session.messages[1]
                x.text += ["Odpoveď. ", "\n\n| a | b |\n|---|---|\n| 1 | 2 |\n", "\n\n- [ ] lístky\n- [ ] kalendár\n", "\n\nMožnosti: Áno | Nie"].randomElement()!; session.messages[1] = x }),
            ("done", { session.running = false; session.status = nil; if app.notch.active { m.finished(session.chatId, failed: false) } }),
            ("undone", { withAnimation(NotchModel.closing) { m.done = nil } }),
            ("proposal", { guard session.messages.count > 1 else { return }; var x = session.messages[1]; x.proposals = [Proposal(id: "p\(Int.random(in: 1...999))", summary: "Udalosť: Kávový festival zajtra 13:00")]; session.messages[1] = x }),
            ("decide", { if session.messages.count > 1, let p = session.messages[1].proposals.first { session.decided[p.id] = true } }),
            ("queue", { session.queue = session.queue.isEmpty ? ["ďalšia otázka"] : [] }),
            ("open", { withAnimation(NotchModel.opening) { m.expanded = true } }),
            ("close", { withAnimation(NotchModel.closing) { m.expanded = false } }),
            ("flash", { m.show("Brain má hotovo", "Test") }),
            ("show", { app.show() }), ("hide", { app.hide() }),
            ("window", { app.openWindow(.chats) }), ("closewin", { app.mainWindow?.close() }),
            ("reset", { session.reset() }),
            // what a real answer does when it ends: the conversation is saved, so the history (and the window's list) changes
            ("save", { if session.messages.count > 1 { session.chatTitle = "🧪 stress test"; session.save(); saved.insert(session.chatId) } }),
            ("save", { if session.messages.count > 1 { session.chatTitle = "🧪 stress test"; session.save(); saved.insert(session.chatId) } }),
            ("chats", { app.openWindow(.chats); app.nav.chat = HistoryStore.shared.chats.first?.id }),
        ]
        let end = Date().addingTimeInterval(seconds)
        var n = 0
        AppDelegate.log("stress start \(Int(seconds))s")
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            MainActor.assumeIsolated {
                if Date() > end {
                    t.invalidate(); session.reset(); app.hide(); app.mainWindow?.close()
                    saved.forEach { HistoryStore.shared.delete($0) }   // the test's conversations leave no trace
                    AppDelegate.log("stress ok \(n) steps"); return
                }
                if session.messages.count < 2 && Bool.random() { steps[0].1() }
                let s = steps.randomElement()!
                s.1(); n += 1
                if n % 50 == 0 { AppDelegate.log("stress \(n): \(s.0)") }
            }
        }
    }
}
