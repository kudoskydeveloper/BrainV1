import AppKit
import Foundation
import MarketCore
import UserNotifications

/// App state: config, live quotes, account, alerts and briefs.
@MainActor
final class Model: ObservableObject {
    @Published var cfg = WatchConfig(symbols: [], moveAlertPct: 3)
    @Published var quotes: [String: Quote] = [:]
    @Published var sparks: [String: [Double]] = [:]
    @Published var account: Account?
    @Published var positions: [Position] = []
    @Published var news: [NewsItem] = []
    @Published var marketOpen = false
    @Published var clock: MarketClock?
    @Published var now = Date()          // ticks every 30 s for the countdowns
    @Published var live = false
    @Published var problem: String?
    @Published var lastBrief: URL?

    var api: Alpaca?
    var stream: LiveStream?
    var timers: [Timer] = []
    var cfgModified: Date?
    let defaults = UserDefaults.standard

    var ordered: [Quote] { cfg.symbols.compactMap { quotes[$0] } }
    var headline: Quote? { cfg.symbols.first.flatMap { quotes[$0] } }

    func start() {
        defaults.register(defaults: ["chimes": true, "closeWarning": true, "menuCountdown": true])
        do {
            cfg = try WatchConfig.load()
            cfgModified = modDate()
            let keys = try Keys.load()
            api = Alpaca(keys: keys)
            let s = LiveStream(keys: keys, symbols: cfg.symbols)
            s.onTrade = { [weak self] sym, price in self?.trade(sym, price) }
            s.onStatus = { [weak self] ok, err in
                guard let self else { return }
                live = ok
                if let e = err { problem = "Live prices: \(e)" } else if problem?.hasPrefix("Live prices") == true { problem = nil }
            }
            s.start()
            stream = s
        } catch {
            problem = error.localizedDescription
            return
        }
        lastBrief = latestBriefFile()
        Task { await refresh(full: true) }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh(full: false) } },
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh(full: true) } },
        ]
    }

    /// Prices and market clock every minute; sparklines, account and positions every five.
    func refresh(full: Bool) async {
        guard let api = api, !cfg.symbols.isEmpty else { return }
        do {
            let c = try await api.clock()
            if c != clock { clock = c; scheduleBells() }
            marketOpen = c.isOpen
            let snap = try await api.snapshots(cfg.symbols)
            for (s, q) in snap {
                // keep a fresher streamed price, but always take the latest previous close
                if var cur = quotes[s], live, marketOpen { cur.prev = q.prev; quotes[s] = cur } else { quotes[s] = q }
            }
            if full {
                sparks = try await api.intraday(cfg.symbols)
                account = try await api.account()
                positions = try await api.positions()
                if marketOpen { checkProtection(try await api.stopOrders()) }
            }
            problem = nil
            checkAlerts()
        } catch {
            problem = error.localizedDescription
        }
    }

    func trade(_ sym: String, _ price: Double) {
        guard var q = quotes[sym] else { return }
        q.last = price
        quotes[sym] = q
        if var sp = sparks[sym], !sp.isEmpty { sp[sp.count - 1] = price; sparks[sym] = sp }
        checkAlerts()
    }

    // MARK: alerts

    var sentKey: String { "sent-" + ISO8601DateFormatter.day.string(from: Date()) }

    func checkAlerts() {
        guard marketOpen else { return }
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let due = Rules.alerts(quotes, cfg, sent: sent)
        guard !due.isEmpty else { return }
        for a in due { Notifier.post(title: "Market alert", body: a.text, id: a.key) }
        defaults.set(Array(sent.union(due.map(\.key))), forKey: sentKey)
        askBrain(due)
    }

    /// Hands the alerts to Brain as a background task (brain://timer, its own chat, answer as a notification): Brain reads the
    /// trading plan, decides what to do with the move and drafts the order for the user's confirm. Off with defaults key brainAlerts = NO.
    func askBrain(_ alerts: [Alert]) {
        guard defaults.object(forKey: "brainAlerts") as? Bool ?? true, !alerts.isEmpty else { return }
        let q = "Market alert z MarketBaru: " + alerts.map(\.text).joined(separator: "; ")
            + ". Prečítaj trading plán a pozície, rozhodni podľa rozhodovacieho protokolu, čo s tým (aj „nerobiť nič“ je rozhodnutie), "
            + "a ak treba, priprav príkaz na potvrdenie."
        var c = URLComponents(); c.scheme = "brain"; c.host = "timer"
        c.queryItems = [.init(name: "in", value: "0"), .init(name: "q", value: q), .init(name: "from", value: "MarketBar")]
        guard let url = c.url else { return }
        let open = NSWorkspace.OpenConfiguration(); open.activates = false
        NSWorkspace.shared.open(url, configuration: open)
    }

    /// Notifies once a day per position that has no stop loss, a partial one, or only a DAY one.
    func checkProtection(_ stops: [StopOrder]) {
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let due = Rules.unprotected(positions, stops, sent: sent)
        guard !due.isEmpty else { return }
        for a in due { Notifier.post(title: "Position without stop loss", body: a.text, id: a.key) }
        defaults.set(Array(sent.union(due.map(\.key))), forKey: sentKey)
    }

    // MARK: open / close bells

    /// Notifications with a chime at the next open and close (and 15 min before the close), scheduled ahead so they ring on time
    /// even between refreshes. Same ids each time, so rescheduling replaces them.
    func scheduleBells() {
        Notifier.cancel(["bell-open", "bell-close", "bell-close-soon"])
        guard let c = clock else { return }
        if defaults.bool(forKey: "chimes") {
            Notifier.schedule(title: "🔔 US market open", body: "Trading starts now. Watchlist: " + cfg.symbols.prefix(6).joined(separator: " · "),
                              id: "bell-open", at: c.nextOpen, sound: "market-open.wav")
            Notifier.schedule(title: "🔕 US market closed", body: "Trading is over for today. DAY orders and DAY stop losses have expired.",
                              id: "bell-close", at: c.nextClose, sound: "market-close.wav")
        }
        if defaults.bool(forKey: "closeWarning") {
            Notifier.schedule(title: "US market closes in 15 min", body: "DAY orders and DAY stop losses expire at the close; positions keep only GTC protection.",
                              id: "bell-close-soon", at: c.nextClose.addingTimeInterval(-15 * 60), sound: nil)
        }
    }

    // MARK: briefs

    func tick() {
        now = Date()
        if let m = modDate(), m != cfgModified { reloadConfig() }   // edited by Claude or by hand
        let done = Set(defaults.stringArray(forKey: "briefSlots") ?? [])
        if let slot = Rules.briefSlot(Date(), done: done) {
            defaults.set(Array(done.union([slot])).suffix(20), forKey: "briefSlots")
            Task { await makeBrief(notify: true) }
        }
    }

    func makeBrief(notify: Bool) async {
        guard let api = api else { return }
        await refresh(full: true)
        news = Rules.pickNews((try? await api.news(cfg.symbols)) ?? [], symbols: cfg.symbols, perSymbol: cfg.newsPerSymbol)
        let day = ISO8601DateFormatter.day.string(from: Date())
        let md = Rules.briefMarkdown(day: day, quotes: quotes.filter { cfg.symbols.contains($0.key) }, account: account, positions: positions, news: news)
        lastBrief = write(md, name: "\(day).md")
        if notify {
            let top = ordered.sorted { abs($0.pct) > abs($1.pct) }.prefix(3).map { String(format: "%@ %+.1f%%", $0.symbol, $0.pct) }
            Notifier.post(title: "Market brief ready", body: top.joined(separator: " · "), id: "brief-\(day)", opensBrief: true)
        }
    }

    /// iCloud first so the brief reaches the phone; local folder if macOS refuses.
    func write(_ text: String, name: String) -> URL? {
        for dir in [Paths.iCloudBriefs, Paths.localBriefs] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch { continue }
        }
        problem = "Could not save the brief"
        return nil
    }

    func latestBriefFile() -> URL? {
        [Paths.iCloudBriefs, Paths.localBriefs]
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "md" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: config

    func modDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.watchlist.path))?[.modificationDate] as? Date
    }

    func reloadConfig() {
        guard let c = try? WatchConfig.load() else { return }
        apply(c, save: false)
    }

    func apply(_ c: WatchConfig, save: Bool) {
        if save {
            do { try c.save() } catch { problem = "Could not save watchlist: \(error.localizedDescription)"; return }
        }
        cfg = (try? WatchConfig.load()) ?? c
        cfgModified = modDate()
        quotes = quotes.filter { cfg.symbols.contains($0.key) }
        stream?.update(symbols: cfg.symbols)
        Task { await refresh(full: true) }
    }
}
