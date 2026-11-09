import AppKit
import BrainCore
import Foundation

struct Message: Identifiable, Equatable {
    let id = UUID()
    let mine: Bool
    var text: String
    /// What Brain did for this answer ("Pozerám kalendár…"), shown as steps while it works, folded after.
    var steps: [String] = []
    /// Brain proposals this answer waits on: cards with Potvrdiť / Upraviť / Zrušiť.
    var proposals: [Proposal] = []
    /// Pictures sent with this question (stored JPEGs), shown as thumbnails over the bubble.
    var images: [URL] = []
}

struct Proposal: Identifiable, Equatable {
    let id: String
    let summary: String
}

/// One conversation in the panel. Follow-ups resume the same Claude Code session, so "yes" can confirm a proposal.
@MainActor
final class Session: ObservableObject {
    @Published var messages: [Message] = []
    @Published var input = ""
    /// Pictures picked from Photos or dropped in, waiting to go with the next question (thumbnails above the input).
    @Published var attachments: [URL] = []
    /// The Photos picker is open: the panel must not hide when it takes key status.
    var picking = false
    @Published var status: String?
    @Published var running = false
    @Published var needsLogin = false
    /// The answer said the account's usage limit is used up: offer signing in with another account.
    @Published var limitHit = false
    /// Pinned: the panel stays open when another app is clicked.
    @Published var pinned = false
    /// Proposals answered with a button: id → confirmed (true) or cancelled (false).
    @Published var decided: [String: Bool] = [:]
    /// Messages written with ⌘Return while Brain works: sent one by one when it is done.
    @Published var queue: [String] = []
    /// Several proposals waiting: what the user marked on each card (id → yes / no) before sending them together.
    @Published var marked: [String: Bool] = [:]
    /// The short bubble ("✓ Potvrdené 2") shown instead of a decision's wording when it is sent.
    var decisionLabels: [String: String] = [:]
    /// Bumped for every run (and on interrupt), so late events of a stopped run don't land in the next answer.
    var generation = 0
    /// When the running answer last showed a sign of life; a run silent for `stallLimit` is stopped (a source that hangs).
    var lastEvent = Date()
    var watchdog: Timer?
    static let stallLimit: TimeInterval = 240
    var sessionId: String?
    let runner = Runner()
    /// The morning brief shown in the panel; sent along with the first question so follow-ups can refer to it.
    var context: String?
    /// This conversation in the history (saved once a question is asked).
    var chatId = UUID()
    var chatCreated = Date()
    var chatTitle: String?
    /// An old conversation whose Claude Code session is gone: its transcript goes along with the next question instead.
    var earlier: String?
    let history = HistoryStore.shared

    func showBrief(_ markdown: String) {
        reset()
        messages = [Message(mine: false, text: markdown)]
        context = markdown
    }

    /// Sends the input, or `text` (a repeated question) without touching what the user is typing.
    /// `attach`: the pictures waiting in the composer go along (by default with the user's own input only).
    func send(_ text: String? = nil, mark: String = "🔁 ", attach: Bool? = nil) {
        var q = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = q.split(separator: " ").map(String.init), cmd = words.first?.lowercased() ?? ""
        if text == nil, ["/repeat", "/opakuj", "/stop", "/zastav"].contains(cmd) { input = ""; repeatCommand(q); return }
        if text == nil, ["/timer", "/timers", "/za", "/neskor", "/neskôr"].contains(cmd) { input = ""; timerCommand(q); return }
        if text == nil, ["/export"].contains(cmd) { input = ""; exportChat(); return }
        // shortcuts that become a question to Brain (they go through its tools; changes still wait for a yes)
        let rest = words.dropFirst().joined(separator: " ")
        if text == nil, ["/uloz", "/ulož", "/save"].contains(cmd) {
            input = ""
            send("Z tohto rozhovoru vyber, čo stojí za uloženie: fakty a rozhodnutia (remember), úlohy (navrhni do Todoistu / Pripomienok), dlhší text alebo podklady (write_file alebo apple_notes_create na vhodné miesto). "
                 + (rest.isEmpty ? "" : "Konkrétne: \(rest). ") + "Ukáž, čo kam pôjde, a ulož až po mojom áno.", mark: "/uloz → ")
            return
        }
        if text == nil, ["/uprac", "/upratat", "/upratať", "/tidy"].contains(cmd) {
            input = ""
            let w = rest.isEmpty ? "Downloads" : rest
            send("Uprac priečinok \(w). Najprv folder_overview (depth 2), zhrň čo tam je a čo vyzerá ako neporiadok, potom navrhni plán cez cleanup_plan: "
                 + "súvisiace súbory do jasných priečinkov, duplikáty a staré inštalátory do Koša, nič dôležité nemaž. Vykonaj až po mojom áno.", mark: "/uprac → ")
            return
        }
        if text == nil, ["/help", "/pomoc", "/prikazy", "/príkazy", "/?", "/"].contains(cmd) {
            input = ""; messages.append(Message(mine: true, text: q)); messages.append(Message(mine: false, text: Self.helpText)); return
        }
        // pictures go with the user's own next question; a question of only pictures asks what's on them
        let images = attach ?? (text == nil) ? attachments : []
        if q.isEmpty && !images.isEmpty { q = images.count == 1 ? "Čo je na tejto fotke?" : "Čo je na týchto fotkách?" }
        guard !q.isEmpty, !running else { return }
        // /courier, /whatsapp, …: use that app for this question
        if text == nil, let app = BrainApps.find(cmd) {
            input = ""
            send("[Použi na to: \(app.name), \(app.hint)] " + (rest.isEmpty ? "Čo je nové?" : rest), mark: "", attach: true)
            if var m = messages.dropLast().last, m.mine { m.text = "/\(app.slug) " + rest; messages[messages.count - 2] = m; save() }
            return
        }
        if ["/login", "/prihlasit", "/prihlásiť"].contains(cmd) { input = ""; login(email: words.dropFirst().first); return }
        if ["/relogin", "/switch", "/prepnut", "/prepnúť", "/iny-ucet", "/iný-účet"].contains(cmd) { input = ""; relogin(email: words.dropFirst().first); return }
        if ["/ucet", "/účet", "/account", "/whoami"].contains(cmd) { input = ""; showAccount(); return }
        if text == nil { input = "" }
        if !images.isEmpty { attachments = [] }
        messages.append(Message(mine: true, text: decisionLabels.removeValue(forKey: q) ?? (text == nil ? q : mark + q), images: images))
        messages.append(Message(mine: false, text: ""))
        if chatTitle == nil { chatTitle = HistoryStore.title(from: q) }
        save()
        running = true
        status = "Thinking…"
        do {
            let prompt = sessionId != nil ? "" : (earlier.map { "Our earlier conversation in the Brain panel (continue it):\n\n\($0)\n\n---\n\n" }
                ?? context.map { "My morning brief from Brain (for context):\n\n\($0)\n\n---\n\n" } ?? "")
            generation += 1
            let g = generation
            lastEvent = Date()
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.generation == g else { t.invalidate(); return }
                    guard Date().timeIntervalSince(self.lastEvent) > Self.stallLimit else { return }
                    t.invalidate()
                    AppDelegate.log("stalled \(Int(Self.stallLimit))s, stopping")
                    self.interrupt(note: "_Brain \(Int(Self.stallLimit / 60)) minúty neodpovedal (niektorý zdroj zrejme visí), tak som to zastavil. Skús to znova._")
                    if !self.queue.isEmpty { self.send(self.queue.removeFirst(), mark: "") }
                }
            }
            let paths = images.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            let note = images.isEmpty ? "" : "\n\n[Prílohy: \(paths.joined(separator: ", "))]"
            try runner.ask(prompt + q + note, images: images, resume: sessionId) { [weak self] e in
                guard let self, generation == g else { return }
                handle(e)
            }
        } catch {
            finish("Could not start Claude Code: \(error.localizedDescription)", error: true)
        }
    }

    /// /ucet: which Claude account Brain asks with.
    func showAccount() {
        guard !running else { return }
        messages.append(Message(mine: true, text: "/ucet"))
        messages.append(Message(mine: false, text: ""))
        Runner.account { [weak self] a in
            self?.appendAnswer(a.map { "Claude účet: **\($0)**" } ?? "Neprihlásený. Napíš `/login`.")
        }
    }

    /// /relogin [e-mail] (or the button when the limit is used up): log out of the current Claude account, then sign in
    /// with another one in the browser. The e-mail only pre-fills the sign-in page.
    func relogin(email: String? = nil) {
        guard !running else { return }
        messages.append(Message(mine: true, text: "/relogin" + (email.map { " \($0)" } ?? "")))
        messages.append(Message(mine: false, text: ""))
        running = true
        status = "Odhlasujem aktuálny účet…"
        Runner.account { [weak self] current in
            Runner.logout { [weak self] ok in
                guard let self else { return }
                running = false
                status = nil
                appendAnswer(ok ? "Odhlásené" + (current.map { " z **\($0)**" } ?? "") + ". Teraz sa prihlás iným účtom (v prehliadači si prípadne vyber alebo prepni účet na claude.ai)."
                                : "Odhlásenie sa nepodarilo, skúšam rovno prihlásenie iným účtom.")
                login(email: email, echo: false)
            }
        }
    }

    /// /login typed in the panel (or the button on the logged-out hint): Claude's sign-in in the browser, then ask again.
    func login(email: String? = nil, echo: Bool = true) {
        guard !running else { return }
        if echo {
            messages.append(Message(mine: true, text: "/login" + (email.map { " \($0)" } ?? "")))
            messages.append(Message(mine: false, text: ""))
        }
        appendAnswer("Otváram prihlásenie do Claude v prehliadači. Prihlás sa tam a vráť sa sem.")
        running = true
        status = "Čakám na prihlásenie v prehliadači…"
        Runner.login(email: email) { [weak self] ok, output in
            guard let self else { return }
            running = false
            status = nil
            if ok {
                needsLogin = false
                limitHit = false
                sessionId = nil
                Runner.account { [weak self] a in self?.appendAnswer("**Prihlásené ✓**" + (a.map { " ako \($0)." } ?? "") + " Môžeš sa pýtať.") }
            } else {
                Runner.loginInTerminal(email: email)
                let url = output.range(of: #"https://\S+"#, options: .regularExpression).map { String(output[$0]) }
                appendAnswer("Prihlásenie na pozadí sa nedokončilo, otvoril som ho v Termináli: dokonči ho tam a potom sa spýtaj znova." + (url.map { "\n\n[Prihlasovacia stránka](\($0))" } ?? ""))
            }
        }
    }

    func handle(_ e: StreamEvent) {
        lastEvent = Date()
        switch e {
        case .started(let s, let ok):
            sessionId = s
            if !ok { status = "Brain MCP did not connect" }
        case .usingTool(let t):
            dropNarration()
            status = label(t)
            if var last = messages.last, !last.mine, last.steps.last != status {
                last.steps.append(status ?? t)
                messages[messages.count - 1] = last
            }
        case .proposal(let id, let summary):
            if var last = messages.last, !last.mine, !last.proposals.contains(where: { $0.id == id }) {
                last.proposals.append(Proposal(id: id, summary: summary))
                messages[messages.count - 1] = last
            }
        case .text(let t):
            segment = (messages.last?.text.isEmpty ?? true) ? 0 : (messages.last!.text.count + 2)
            appendAnswer(t)
            if StreamParser.needsLogin(t) { needsLogin = true }
            if StreamParser.limitReached(t) { limitHit = true }
        case .finished(let result, let s, let isError):
            if let s = s { sessionId = s }
            if messages.last?.text.isEmpty ?? true, !result.isEmpty { appendAnswer(result) }
            if StreamParser.needsLogin(result) { needsLogin = true }
            if StreamParser.limitReached(result) { limitHit = true }
            finish(nil, error: isError && (messages.last?.text.isEmpty ?? true))
        }
    }

    /// Where the latest text from Claude starts in the answer (before it: earlier text of this turn).
    var segment: Int?

    /// Text written just before a tool call ("Prečítam celé vlákno…") is narration, not the answer: it leaves the answer (the
    /// status line already says which tool runs). Only short single paragraphs: anything longer may be real content and stays.
    func dropNarration() {
        defer { segment = nil }
        guard let start = segment, var last = messages.last, !last.mine, start <= last.text.count else { return }
        let tail = String(last.text.dropFirst(start)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty, tail.count <= 220, !tail.contains("\n") else { return }
        last.text = String(last.text.prefix(max(0, start - 2)))
        messages[messages.count - 1] = last
    }

    func appendAnswer(_ t: String) {
        guard var last = messages.last, !last.mine else { return }
        last.text += (last.text.isEmpty ? "" : "\n\n") + t
        messages[messages.count - 1] = last
    }

    /// Called when an answer is complete (text, whether it failed), e.g. to notify when the panel is hidden.
    var onFinished: ((String, Bool) -> Void)?

    func finish(_ note: String?, error: Bool) {
        if let n = note { appendAnswer(n) } else if error { appendAnswer("Something went wrong. Try again, or check that `claude` works in Terminal.") }
        running = false
        status = nil
        if sessionId != nil { earlier = nil }
        save()
        onFinished?(messages.last(where: { !$0.mine })?.text ?? "", error)
        if !queue.isEmpty {   // ⌘Return messages written meanwhile
            let next = queue.removeFirst()
            DispatchQueue.main.async { [weak self] in self?.send(next, mark: "") }
        }
    }

    func label(_ tool: String) -> String {
        [ "where_is": "Searching your files…", "search_everywhere": "Asking every source…", "recall": "Checking your notes…",
          "remember": "Saving a note…", "capabilities": "Looking up tools…", "call": "Running a tool…", "confirm": "Doing it…",
          "file_action": "Working on files…", "overview": "Looking around…", "scan_now": "Rescanning…",
          "calendar_events": "Pozerám kalendár…", "calendar_free": "Hľadám voľný čas…", "calendar_create": "Pripravujem udalosť…",
          "meeting_prep": "Pripravujem ťa na meeting…", "client": "Zbieram všetko o klientovi…", "semantic_search": "Hľadám podľa významu…",
          "who": "Pozerám, kto to je…", "morning_brief": "Skladám ranný prehľad…", "shopping_list": "Pozerám nákupný zoznam…",
          "shopping_add": "Pridávam do nákupu…", "reminders_list": "Pozerám pripomienky…", "reminders_add": "Pridávam pripomienku…",
          "idoklad_invoices": "Pozerám faktúry v iDoklade…", "idoklad_invoice": "Pripravujem faktúru…", "apple_notes_list": "Prechádzam Apple Notes…",
          "market_overview": "Pozerám trhy a Alpaca účet…", "market_briefs": "Čítam MarketBar brief…", "marketbar": "Otváram MarketBar…",
          "whatsapp_read": "Čítam WhatsApp…", "whatsapp_search": "Hľadám vo WhatsAppe…",
          "WebSearch": "Hľadám na webe…", "WebFetch": "Čítam stránku…" ][tool] ?? "Using \(tool)…"
    }

    // MARK: commands typed in the panel (the info popover and /help list them)

    static let commands: [(String, String)] = [
        ("/repeat 1m 30m <otázka>", "opakovať otázku v tomto rozhovore každú minútu 30 min (alias /opakuj)"),
        ("/stop", "zastaviť /repeat"),
        ("/timer 1h <úloha>", "raz neskôr (aj /timer 15:30 …, alias /za); výsledok ako notifikácia"),
        ("/timer každých 15m na 2h <úloha>", "opakovane na pozadí, vždy s koncom (aj … do 18:00 …)"),
        ("/timer 18:00 urob: <úloha>", "timer to rovno vykoná bez pýtania (obchody nikdy)"),
        ("/timer pripomeň 8:00 <text>", "len pripomienka (notifikácia), nič sa nespustí"),
        ("/timer · /timer stop 2 · /timer stop všetky", "číslovaný zoznam · zrušiť jeden (číslo alebo slová z úlohy) · všetky"),
        ("/export", "uložiť celý rozhovor ako Markdown do Dokumenty/Brain exporty"),
        ("/uloz [čo/kam]", "Brain vyberie dôležité (fakty, úlohy, podklady) a uloží po tvojom áno"),
        ("/uprac [kde]", "upratať Downloads, Desktop, Google Drive, iCloud Drive alebo cestu (jeden plán, jedno áno)"),
        ("/login · /relogin [e-mail] · /ucet", "Claude účet: prihlásiť, prepnúť, ktorý"),
        ("/help", "tento zoznam"),
    ]
    static let shortcuts: [(String, String)] = [("⌥Space", "otvoriť Brain"), ("⇧↩", "nový riadok"), ("⌘R", "nový rozhovor"), ("⌘Y", "rozhovory (okno Brain)"),
                                                 ("⌘⇧C", "kopírovať odpoveď"), ("⌘↩", "pokračovať v Claude"), ("⌘K", "čo Brain vie (okno Brain)"), ("⌘,", "nastavenia"), ("⌘0", "okno Brain")]

    static var helpText: String {
        "## Príkazy\n| Príkaz | Čo robí |\n|---|---|\n" + commands.map { "| `\($0.0)` | \($0.1) |" }.joined(separator: "\n")
            + "\n\n**Skratky:** " + shortcuts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
            + "\n\nTimery a opakovanie vieš zadať aj bežnou rečou, napr. „o hodinu skontroluj moje pozície“."
    }

    // MARK: timer: ask something once, later, in a conversation of its own (TimerStore)

    static let timerHelp = "Použitie: `/timer <za koľko> <otázka>` alebo `/timer <HH:MM> <otázka>`, napr. `/timer 1h skontroluj moje pozície`, `/za 30m pozri NVDA`, `/timer 15:30 aké sú správy k AMD`. Opakovane: `/timer každých 15m na 2h skontroluj NVDA` alebo `… do 18:00 …` (vždy s koncom, najviac 7 dní). So `urob:` to timer rovno vykoná bez pýtania, napr. `/timer 18:00 urob: pošli Jane na WhatsApp „idem domov“` (obchody nikdy). `/timer pripomeň 8:00 <text>` je len pripomienka. `/timer` ukáže číslovaný zoznam, `/timer stop 2` zruší jeden (aj slovami z úlohy), `/timer stop všetky` všetky. Výsledok príde ako notifikácia a nový rozhovor v histórii."

    /// "1h", "30m" → seconds from now; "15:30" → until the next 15:30.
    static func delay(_ s: String) -> TimeInterval? {
        if let m = s.wholeMatch(of: #/(\d{1,2})[:.](\d{2})/#), let h = Int(m.1), let mi = Int(m.2), h < 24, mi < 60 {
            var d = Calendar.current.date(bySettingHour: h, minute: mi, second: 0, of: Date())!
            if d <= Date() { d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
            return d.timeIntervalSinceNow
        }
        return duration(s)
    }

    func timerCommand(_ q: String) {
        var words = q.split(separator: " ").map(String.init)
        words.removeFirst()
        let store = TimerStore.shared, f = Date.FormatStyle(date: .abbreviated, time: .shortened)
        messages.append(Message(mine: true, text: q))
        if words.isEmpty {
            appendNote(store.jobs.isEmpty ? "Žiadne naplánované timery. " + Self.timerHelp
                       : "**Naplánované:**\n" + Self.timerLines(store.jobs) + "\n\nZrušíš jeden `/timer stop 1` (číslo alebo slová z úlohy), všetky `/timer stop všetky`.")
            return
        }
        if ["stop", "zrus", "zruš", "cancel", "zmaz", "zmaž"].contains(words[0].lowercased()) {
            let what = words.dropFirst().joined(separator: " ")
            if store.jobs.isEmpty { appendNote("Nebol naplánovaný žiadny timer."); return }
            let all = ["všetky", "vsetky", "all", "*"].contains(what.lowercased())
            if what.isEmpty && store.jobs.count > 1 {
                appendNote("Ktorý? Napíš `/timer stop <číslo>` (aj viac, napr. `1 3`), slová z úlohy, alebo `/timer stop všetky`.\n\n" + Self.timerLines(store.jobs))
                return
            }
            let hit = all || what.isEmpty ? store.jobs : store.find(what)
            if hit.isEmpty { appendNote("Na „\(what)“ nesedí žiadny timer.\n\n" + Self.timerLines(store.jobs)); return }
            if hit.count > 1 && !all && Int(what.split(separator: " ").first ?? "") == nil {
                appendNote("Sedí viac timerov, upresni číslom:\n\n" + Self.timerLines(store.jobs)); return
            }
            let gone = store.cancel(hit.map(\.id))
            appendNote("Zrušené (\(gone.count)):\n" + gone.map { "- ~~" + $0.at.formatted(f) + ": " + Self.short($0.prompt) + "~~" }.joined(separator: "\n")
                       + (store.jobs.isEmpty ? "\n\nĎalšie timery nie sú." : "\n\n**Zostáva:**\n" + Self.timerLines(store.jobs)))
            return
        }
        // recurring: "každých 15m na 2h …" / "každých 15m do 18:00 …"; without an end, ask for one: nothing runs forever
        var every: TimeInterval?, until: Date?
        if ["každých", "kazdych", "každú", "kazdu", "every"].contains(words[0].lowercased()) {
            words.removeFirst()
            guard let e = words.first.flatMap(Self.duration), e >= 60 else { appendNote(Self.timerHelp); return }
            every = e; words.removeFirst()
            let w = words.first?.lowercased()
            if ["na", "for"].contains(w), words.count > 1, let d = Self.duration(words[1]) { until = Date().addingTimeInterval(d); words.removeFirst(2) }
            else if ["do", "until"].contains(w), words.count > 1, let d = Self.delay(words[1]) { until = Date().addingTimeInterval(d); words.removeFirst(2) }
            else {
                appendNote("Dokedy to mám robiť? Opakovaná úloha musí mať koniec, napr. `/timer každých \(Self.human(e)) na 2h \(words.joined(separator: " "))` alebo `… do 18:00 …` (najviac 7 dní).")
                return
            }
            words.insert("0s", at: 0)   // the first run right away
        }
        guard let wait = Self.delay(words.removeFirst()), wait >= (every == nil ? 30 : 0), !words.isEmpty else { appendNote(Self.timerHelp); return }
        guard wait <= 7 * 86400 else { appendNote("Najviac 7 dní dopredu."); return }
        // "urob:" / "do:" in front: approved in advance, the timer carries it out (trades still wait for a yes)
        var approved = false, remind = false
        if let w = words.first?.lowercased(), ["urob:", "urob", "do:", "!"].contains(w) { approved = true; words.removeFirst() }
        else if let w = words.first?.lowercased(), ["pripomeň:", "pripomeň", "pripomen:", "pripomen", "remind:", "remind"].contains(w) { remind = true; words.removeFirst() }
        guard !words.isEmpty else { appendNote(Self.timerHelp); return }
        let j = store.add(words.joined(separator: " "), in: wait, from: chatTitle, approved: approved, remind: remind, every: every, until: until)
        if remind && every == nil {
            appendNote("⏰ \(j.at.formatted(f)) ti pripomeniem: „\(j.prompt)“ (len notifikácia, nič sa nespustí). Zrušíš `/timer stop \(store.jobs.firstIndex { $0.id == j.id }.map { $0 + 1 } ?? 1)`.")
            return
        }
        if let e = j.every, let u = j.until {
            appendNote("🔁 Každých \(Self.human(e)) do \(u.formatted(f)) (\(min(Int(u.timeIntervalSinceNow / e) + 1, TimerStore.maxRuns))× , prvé teraz) "
                + (approved ? "urobím" : "sa spýtam") + ": „\(j.prompt)“. Každé kolo je jedna otázka Claudovi (tokeny). Výsledky prídu ako notifikácie a jeden rozhovor v histórii. Zrušíš `/timer stop \(store.jobs.firstIndex { $0.id == j.id }.map { $0 + 1 } ?? 1)`.")
            return
        }
        appendNote("⏰ \(j.at.formatted(f)) " + (approved ? "urobím: „\(j.prompt)“ (bez ďalšieho pýtania; obchody aj tak počkajú na tvoje áno)." : "sa spýtam: „\(j.prompt)“ (zmeny ti dám na potvrdenie).")
                   + " Výsledok príde ako notifikácia a nový rozhovor v histórii (⌘Y). Zrušíš `/timer stop \(store.jobs.firstIndex { $0.id == j.id }.map { $0 + 1 } ?? 1)`.")
    }

    /// The /timer list: numbered (the numbers `/timer stop` takes), what each does, short.
    static func timerLines(_ jobs: [TimerStore.Job]) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .shortened).weekday(.abbreviated)
        return jobs.enumerated().map { i, j in
            let rep = j.every.map { e in " 🔁 každých \(human(e)) do \(j.until?.formatted(f) ?? "?")" } ?? ""
            let mode = j.remind == true ? "🔔 pripomenie" : j.approved == true ? "⚡️ urobí sám" : "❓ spýta sa"
            return "\(i + 1). **\(j.at.formatted(f))**\(rep) · \(mode): \(short(j.prompt))"
        }.joined(separator: "\n")
    }

    static func short(_ s: String, _ n: Int = 110) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    func appendNote(_ t: String) { messages.append(Message(mine: false, text: t)); save() }

    /// /export: the conversation as a Markdown file in ~/Documents/Brain exporty, shown in Finder.
    func exportChat() {
        let talk = messages.filter { !$0.text.isEmpty }
        guard !talk.isEmpty else { messages.append(Message(mine: false, text: "Nie je čo exportovať.")); return }
        let dir = Runner.home.appendingPathComponent("Documents/Brain exporty")
        let title = (chatTitle ?? "Rozhovor").replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(80)
        let file = dir.appendingPathComponent("\(title) \(Date().formatted(.iso8601.year().month().day())).md")
        let md = "# \(chatTitle ?? "Rozhovor s Brainom")\n\nExport z Brainu, \(Date().formatted(date: .long, time: .shortened)).\n\n"
            + talk.map { ($0.mine ? "**Ja:** " : "**Brain:**\n\n") + $0.text }.joined(separator: "\n\n---\n\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try md.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            let link = file.absoluteString
            messages.append(Message(mine: true, text: "/export"))
            appendNote("Uložené: [\(file.lastPathComponent)](\(link))")
        } catch {
            appendNote("Export sa nepodaril: \(error.localizedDescription)")
        }
    }

    // MARK: repeat: ask the same thing again every so often, in this conversation, for a limited time

    struct Repeat: Equatable { let prompt: String; let every: TimeInterval; let until: Date }
    /// The question being repeated in this conversation; it stops at `until`, on /stop, or when another conversation is opened.
    @Published var repeating: Repeat?
    var repeatTimer: Timer?
    static let repeatHelp = "Použitie: `/repeat <každých> [na ako dlho] <otázka>`, napr. `/repeat 1m 30m skontroluj moje pozície` (každú minútu, 30 minút). Bez dĺžky beží 30 min, najviac 8 h. Zastavíš to `/stop`, tlačidlom Zastaviť alebo novým rozhovorom."

    /// "90s", "1m", "15min", "2h" → seconds.
    static func duration(_ s: String) -> TimeInterval? {
        let m = s.lowercased().wholeMatch(of: #/(\d+(?:[.,]\d+)?)\s*(s|sek|m|min|h|hod)?/#)
        guard let m, let n = Double(m.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
        switch m.2.map(String.init) ?? "m" { case "s", "sek": return n; case "h", "hod": return n * 3600; default: return n * 60 }
    }

    func repeatCommand(_ q: String) {
        var words = q.split(separator: " ").map(String.init)
        let cmd = words.removeFirst().lowercased()
        if ["/stop", "/zastav"].contains(cmd) || words.first?.lowercased() == "stop" { stopRepeat("Opakovanie som zastavil."); return }
        guard let every = words.first.flatMap(Self.duration) else { messages.append(Message(mine: false, text: Self.repeatHelp)); return }
        words.removeFirst()
        var length: TimeInterval = 30 * 60
        if let d = words.first.flatMap(Self.duration) { length = d; words.removeFirst() }
        let prompt = words.joined(separator: " ")
        guard !prompt.isEmpty else { messages.append(Message(mine: false, text: Self.repeatHelp)); return }
        let step = max(every, 60), span = min(max(length, step), 8 * 3600)
        let r = Repeat(prompt: prompt, every: step, until: Date().addingTimeInterval(span))
        stopRepeat(nil)
        repeating = r
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        messages.append(Message(mine: true, text: q))
        messages.append(Message(mine: false, text: "🔁 Budem sa pýtať „\(prompt)“ každých \(Self.human(step)) do \(r.until.formatted(f)) (\(Int(span / step) + 1)× vrátane teraz). "
            + "Každé opakovanie je jedna otázka Claudovi, teda míňa tokeny. Zastavíš to `/stop`, tlačidlom alebo novým rozhovorom."))
        if chatTitle == nil { chatTitle = HistoryStore.title(from: prompt) }
        save()
        tick()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    func tick() {
        guard let r = repeating else { return }
        if Date() > r.until.addingTimeInterval(1) { stopRepeat("🔁 Opakovanie skončilo (\(r.until.formatted(Date.FormatStyle(date: .omitted, time: .shortened))))."); return }
        if !running { send(r.prompt) }   // still answering the previous one: skip this round
    }

    func stopRepeat(_ note: String?) {
        repeatTimer?.invalidate(); repeatTimer = nil
        guard repeating != nil else { return }
        repeating = nil
        if let note { messages.append(Message(mine: false, text: note)); save() }
    }

    static func human(_ t: TimeInterval) -> String {
        t >= 3600 ? "\(Int(t / 3600)) h" + (Int(t) % 3600 >= 60 ? " \(Int(t) % 3600 / 60) min" : "") : "\(Int(t / 60)) min"
    }

    /// A proposal card's button: confirm or cancel through Claude (it calls confirm, so the conversation knows what happened).
    func decide(_ p: Proposal, _ yes: Bool) { decide([(p, yes)]) }

    /// One message for any number of proposals; while Brain works it waits in the queue and goes right after.
    func decide(_ list: [(Proposal, Bool)]) {
        guard !list.isEmpty else { return }
        for (p, y) in list { decided[p.id] = y; marked[p.id] = nil }
        let yes = list.filter(\.1).map(\.0.id), no = list.filter { !$0.1 }.map(\.0.id)
        var parts: [String] = []
        if !yes.isEmpty { parts.append(yes.count == 1 ? "Áno, potvrď to (\(yes[0]))." : "Áno, potvrď všetky tieto návrhy: \(yes.joined(separator: ", ")).") }
        if !no.isEmpty { parts.append(no.count == 1 ? "Toto nepotvrdzuj (\(no[0])) a nič s tým nerob." : "Tieto nepotvrdzuj a nič s nimi nerob: \(no.joined(separator: ", ")).") }
        let text = parts.joined(separator: " ")
        decisionLabels[text] = [yes.isEmpty ? nil : yes.count == 1 ? "✓ Potvrdené" : "✓ Potvrdené \(yes.count)",
                                no.isEmpty ? nil : no.count == 1 ? "✕ Zrušené" : "✕ Zrušené \(no.count)"].compactMap { $0 }.joined(separator: " · ")
        if running { queue.append(text) } else { send(text, mark: "") }
    }

    /// Return in the field: send now; while Brain works, stop it and send this instead (it continues the same conversation).
    /// ⌘Return while it works: queue it for when it's done.
    func submit(queued: Bool) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        guard running else { send(); return }
        if queued && attachments.isEmpty { queue.append(t); input = ""; return }   // pictures aren't queued: they go now
        interrupt()
        send()
    }

    /// Stops the answer being written; what came so far stays, marked as interrupted.
    func interrupt(note: String = "_Prerušené._") {
        guard running else { return }
        watchdog?.invalidate()
        generation += 1
        runner.stop()
        running = false
        status = nil
        if var last = messages.last, !last.mine {
            last.text += last.text.isEmpty ? note : "\n\n" + note
            messages[messages.count - 1] = last
        }
        save()
    }

    /// An option or checklist button: answer with that text.
    func reply(_ text: String) { guard !running else { return }; input = ""; send(text, mark: "") }

    func reset() {
        stopRepeat(nil)
        generation += 1
        runner.stop()
        messages = []; input = ""; attachments = []; decided = [:]; marked = [:]; queue = []; sessionId = nil; running = false; status = nil; needsLogin = false; limitHit = false; context = nil
        chatId = UUID(); chatCreated = Date(); chatTitle = nil; earlier = nil
    }

    /// Keeps this conversation in the history, once it has a question in it.
    func save() {
        guard let title = chatTitle else { return }
        history.save(Chat(id: chatId, title: history.chats.first { $0.id == chatId }?.title ?? title, created: chatCreated, updated: Date(),
                          sessionId: sessionId, context: context,
                          messages: messages.map { .init(mine: $0.mine, text: $0.text, images: $0.images.isEmpty ? nil : $0.images.map(\.path)) }))
    }

    /// Opens a saved conversation; the next question continues its Claude Code session (or, if that's gone, gets the transcript).
    func open(_ c: Chat) {
        reset()
        messages = c.messages.map { Message(mine: $0.mine, text: $0.text, images: ($0.images ?? []).map { URL(fileURLWithPath: $0) }) }
        chatId = c.id; chatCreated = c.created; chatTitle = c.title; context = c.context
        if let s = c.sessionId, HistoryStore.sessionExists(s) { sessionId = s } else { earlier = transcript }
    }

    /// Adds pictures (data from the Photos picker or a drop, or image files) to the next question.
    func attach(_ data: Data) { if let u = Attachments.store(data) { attachments.append(u) } }
    func attach(file: URL) { if let u = Attachments.store(file: file) { attachments.append(u) } }

    var transcript: String {
        messages.map { ($0.mine ? "Me: " : "Brain: ") + $0.text }.joined(separator: "\n\n")
    }

    /// Bigger tasks: copy the conversation and open Claude Desktop, ready to paste.
    func continueInClaude() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Continuing from my Brain panel (use the brain tools):\n\n" + transcript, forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
    }
}
