import Foundation

public struct Quote: Equatable {
    public var symbol: String
    public var last: Double
    public var prev: Double
    public var pct: Double { prev > 0 ? (last - prev) / prev * 100 : 0 }
    public init(symbol: String, last: Double, prev: Double) { self.symbol = symbol; self.last = last; self.prev = prev }
}

public struct Account: Equatable {
    public var equity, lastEquity, cash, buyingPower: Double
    public var plToday: Double { equity - lastEquity }
}

public struct Position: Equatable, Identifiable {
    public var id: String { symbol }
    public var symbol: String
    public var qty, price, pl, plPct: Double
}

/// A working stop, stop-limit or trailing-stop order (bracket and OCO legs included): what protects a position.
public struct StopOrder: Equatable {
    public var symbol: String
    public var side: String     // "sell" protects a long
    public var qty: Double      // still unfilled
    public var day: Bool        // time in force DAY: lapses at the close
    public var stopPrice: Double
    public init(symbol: String, side: String, qty: Double, day: Bool, stopPrice: Double = 0) {
        self.symbol = symbol; self.side = side; self.qty = qty; self.day = day; self.stopPrice = stopPrice
    }
}

public struct NewsItem: Equatable, Identifiable {
    public var id: Int
    public var headline: String
    public var url: String
    public var symbols: [String]
    public var date: Date
}

/// Alpaca REST, paper trading endpoint only.
public final class Alpaca {
    static let trading = URL(string: "https://paper-api.alpaca.markets")!
    static let data = URL(string: "https://data.alpaca.markets")!
    let keys: Keys
    let session = URLSession(configuration: .ephemeral)

    public init(keys: Keys) { self.keys = keys }

    func get(_ base: URL, _ path: String, _ query: [String: String] = [:]) async throws -> Any {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue(keys.id, forHTTPHeaderField: "APCA-API-KEY-ID")
        req.setValue(keys.secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw MarketError.message("Alpaca \(code) on \(path): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    public func clock() async throws -> MarketClock {
        guard let c = Parse.clock(try await get(Self.trading, "/v2/clock") as? [String: Any] ?? [:]) else { throw MarketError.message("Alpaca clock: unexpected answer") }
        return c
    }

    public func account() async throws -> Account {
        let d = try await get(Self.trading, "/v2/account") as? [String: Any] ?? [:]
        func n(_ k: String) -> Double { Double(d[k] as? String ?? "") ?? 0 }
        return Account(equity: n("equity"), lastEquity: n("last_equity"), cash: n("cash"), buyingPower: n("buying_power"))
    }

    public func positions() async throws -> [Position] {
        (try await get(Self.trading, "/v2/positions") as? [[String: Any]] ?? []).map { d in
            func n(_ k: String) -> Double { Double(d[k] as? String ?? "") ?? 0 }
            return Position(symbol: d["symbol"] as? String ?? "?", qty: n("qty"), price: n("current_price"),
                            pl: n("unrealized_pl"), plPct: n("unrealized_plpc") * 100)
        }
    }

    /// Working stop orders; "all" because a bracket's held stop leg only shows up nested in its filled parent.
    public func stopOrders() async throws -> [StopOrder] {
        Parse.stopOrders(try await get(Self.trading, "/v2/orders", ["status": "all", "limit": "200", "nested": "true", "direction": "desc"]) as? [[String: Any]] ?? [])
    }

    public func snapshots(_ symbols: [String]) async throws -> [String: Quote] {
        let d = try await get(Self.data, "/v2/stocks/snapshots", ["symbols": symbols.joined(separator: ","), "feed": "iex"])
        return Parse.snapshots(d as? [String: Any] ?? [:])
    }

    /// Intraday 15-minute closes for the most recent trading day, for sparklines.
    public func intraday(_ symbols: [String]) async throws -> [String: [Double]] {
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-4 * 86400))
        let d = try await get(Self.data, "/v2/stocks/bars", ["symbols": symbols.joined(separator: ","), "timeframe": "15Min",
                                                               "start": start, "feed": "iex", "limit": "10000"])
        return Parse.lastDayCloses((d as? [String: Any])?["bars"] as? [String: [[String: Any]]] ?? [:])
    }

    public func news(_ symbols: [String], limit: Int = 50) async throws -> [NewsItem] {
        let d = try await get(Self.data, "/v1beta1/news", ["symbols": symbols.joined(separator: ","), "limit": String(limit)])
        return Parse.news((d as? [String: Any])?["news"] as? [[String: Any]] ?? [])
    }
}

/// JSON → models. Separate so tests can feed recorded payloads.
public enum Parse {
    public static func snapshots(_ d: [String: Any]) -> [String: Quote] {
        var out: [String: Quote] = [:]
        for (sym, v) in d {
            guard let s = v as? [String: Any] else { continue }
            let prev = ((s["prevDailyBar"] as? [String: Any])?["c"] as? NSNumber)?.doubleValue
            let last = ((s["latestTrade"] as? [String: Any])?["p"] as? NSNumber)?.doubleValue
                ?? ((s["dailyBar"] as? [String: Any])?["c"] as? NSNumber)?.doubleValue
            if let p = prev, let l = last, p > 0 { out[sym] = Quote(symbol: sym, last: l, prev: p) }
        }
        return out
    }

    public static func lastDayCloses(_ bars: [String: [[String: Any]]]) -> [String: [Double]] {
        bars.mapValues { list in
            guard let lastDay = (list.last?["t"] as? String)?.prefix(10) else { return [] }
            return list.filter { ($0["t"] as? String)?.prefix(10) == lastDay }.compactMap { ($0["c"] as? NSNumber)?.doubleValue }
        }
    }

    static let working: Set<String> = ["new", "accepted", "held", "partially_filled", "pending_new", "pending_replace", "accepted_for_bidding"]
    static let stopTypes: Set<String> = ["stop", "stop_limit", "trailing_stop"]

    public static func stopOrders(_ list: [[String: Any]]) -> [StopOrder] {
        let flat = list.flatMap { [$0] + ($0["legs"] as? [[String: Any]] ?? []) }
        return flat.compactMap { o in
            guard let s = o["status"] as? String, working.contains(s), let t = o["type"] as? String, stopTypes.contains(t) else { return nil }
            func n(_ k: String) -> Double { Double(o[k] as? String ?? "") ?? 0 }
            return StopOrder(symbol: o["symbol"] as? String ?? "?", side: o["side"] as? String ?? "", qty: n("qty") - n("filled_qty"),
                             day: (o["time_in_force"] as? String) == "day", stopPrice: n("stop_price"))
        }
    }

    public static func news(_ list: [[String: Any]]) -> [NewsItem] {
        let iso = ISO8601DateFormatter()
        return list.compactMap { d in
            guard let id = d["id"] as? Int, let h = d["headline"] as? String else { return nil }
            return NewsItem(id: id, headline: h, url: d["url"] as? String ?? "", symbols: d["symbols"] as? [String] ?? [],
                            date: iso.date(from: d["created_at"] as? String ?? "") ?? Date())
        }
    }

    /// One message from the live stream: an array of events. Returns (symbol, price) for each trade.
    public static func streamTrades(_ data: Data) -> [(String, Double)] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard e["T"] as? String == "t", let s = e["S"] as? String, let p = (e["p"] as? NSNumber)?.doubleValue else { return nil }
            return (s, p)
        }
    }

    /// Stream control messages worth surfacing (auth failures, connection limits).
    public static func streamAuthenticated(_ data: Data) -> Bool {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return arr.contains { $0["T"] as? String == "success" && $0["msg"] as? String == "authenticated" }
    }

    public static func streamErrors(_ data: Data) -> [String] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["T"] as? String == "error" ? "\($0["code"] ?? ""): \($0["msg"] ?? "")" : nil }
    }
}
