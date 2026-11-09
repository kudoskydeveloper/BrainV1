import Foundation

public struct Alert: Equatable {
    public var key: String    // one alert per key per day
    public var text: String
}

public enum Rules {
    /// Alerts due now, minus those already sent today.
    public static func alerts(_ quotes: [String: Quote], _ cfg: WatchConfig, sent: Set<String>) -> [Alert] {
        var out: [Alert] = []
        if cfg.moveAlertPct > 0 {
            for q in quotes.values.sorted(by: { $0.symbol < $1.symbol }) where cfg.symbols.contains(q.symbol) && abs(q.pct) >= cfg.moveAlertPct {
                out.append(Alert(key: "move:\(q.symbol):\(q.pct > 0 ? "up" : "down")",
                                 text: String(format: "%@ %+.1f%% at %.2f", q.symbol, q.pct, q.last)))
            }
        }
        for l in cfg.levels {
            guard let q = quotes[l.symbol] else { continue }
            if l.above > 0 && q.last >= l.above {
                out.append(Alert(key: "above:\(l.symbol):\(l.above)", text: String(format: "%@ above %g (now %.2f)", l.symbol, l.above, q.last)))
            }
            if l.below > 0 && q.last <= l.below {
                out.append(Alert(key: "below:\(l.symbol):\(l.below)", text: String(format: "%@ below %g (now %.2f)", l.symbol, l.below, q.last)))
            }
        }
        return out.filter { !sent.contains($0.key) }
    }

    /// Positions without a lasting stop loss: none, only part of the shares, or only DAY stops that lapse at the close.
    /// One alert per position and state per day (same "sent" set as price alerts).
    public static func unprotected(_ positions: [Position], _ stops: [StopOrder], sent: Set<String>) -> [Alert] {
        positions.sorted { $0.symbol < $1.symbol }.compactMap { p -> Alert? in
            let held = abs(p.qty), side = p.qty > 0 ? "sell" : "buy"
            let mine = stops.filter { $0.symbol == p.symbol && $0.side == side }
            let all = min(mine.reduce(0) { $0 + $1.qty }, held), gtc = min(mine.filter { !$0.day }.reduce(0) { $0 + $1.qty }, held)
            let shares = String(format: "%g", held)
            if gtc >= held { return nil }
            if all == 0 { return Alert(key: "unprotected:\(p.symbol):none", text: "\(p.symbol) \(shares) shares have no stop loss") }
            if all < held { return Alert(key: "unprotected:\(p.symbol):partial", text: "\(p.symbol): stop loss covers \(String(format: "%g", all)) of \(shares) shares") }
            let at = Set(mine.filter(\.day).map { String(format: "%g", $0.stopPrice) }).sorted().joined(separator: "/")
            return Alert(key: "unprotected:\(p.symbol):day", text: "\(p.symbol) \(shares) shares: stop loss \(at) is DAY only and lapses at the close; set a GTC one (Brain: propose_exit)")
        }.filter { !sent.contains($0.key) }
    }

    /// Brief due at 08:30 and 15:15 on weekdays (local time). Returns the slot id, e.g. "2026-11-04 08:30".
    public static func briefSlot(_ now: Date, calendar: Calendar = .current, done: Set<String>) -> String? {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return nil }
        let day = ISO8601DateFormatter.day.string(from: now)
        for (sh, sm) in [(8, 30), (15, 15)] {
            let mins = h * 60 + m - (sh * 60 + sm)
            let slot = String(format: "%@ %02d:%02d", day, sh, sm)
            if (0..<60).contains(mins) && !done.contains(slot) { return slot }   // catch up within an hour (e.g. after wake)
        }
        return nil
    }

    public static func pickNews(_ items: [NewsItem], symbols: [String], perSymbol: Int) -> [NewsItem] {
        var count: [String: Int] = [:], out: [NewsItem] = []
        for n in items {
            let hit = n.symbols.filter { symbols.contains($0) && count[$0, default: 0] < perSymbol }
            guard !hit.isEmpty else { continue }
            hit.forEach { count[$0, default: 0] += 1 }
            out.append(n)
        }
        return out
    }

    public static func briefMarkdown(day: String, quotes: [String: Quote], account: Account?, positions: [Position], news: [NewsItem]) -> String {
        var l = ["# Market brief \(day)", ""]
        if let a = account {
            let pct = a.lastEquity > 0 ? a.plToday / a.lastEquity * 100 : 0
            l += ["## Paper account", String(format: "Equity %.2f USD (%+.2f, %+.2f%% today) · cash %.2f", a.equity, a.plToday, pct, a.cash), ""]
        }
        if !positions.isEmpty {
            l += ["| Position | Qty | Price | P/L | P/L % |", "|---|---:|---:|---:|---:|"]
            l += positions.map { String(format: "| %@ | %g | %.2f | %+.2f | %+.1f%% |", $0.symbol, $0.qty, $0.price, $0.pl, $0.plPct) }
            l.append("")
        }
        l += ["## Watchlist", "| Symbol | Last | Prev close | Change |", "|---|---:|---:|---:|"]
        l += quotes.values.sorted { abs($0.pct) > abs($1.pct) }.map { String(format: "| %@ | %.2f | %.2f | %+.2f%% |", $0.symbol, $0.last, $0.prev, $0.pct) }
        if !news.isEmpty {
            l += ["", "## News"] + news.map { "- **\($0.symbols.prefix(3).joined(separator: ", "))**: [\($0.headline)](\($0.url))" }
        }
        l += ["", "_Alpaca paper account, IEX prices. For your own tracking, not advice._"]
        return l.joined(separator: "\n") + "\n"
    }
}

public extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()
}
