import Foundation

/// Paths shared with the Python tools in ~/Developer/market-alerts.
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let watchlist = home.appendingPathComponent("Developer/market-alerts/watchlist.json")
    public static let keys = home.appendingPathComponent(".config/market-alerts/keys.env")
    public static let iCloudBriefs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Personal/Finance/Market briefs")
    public static let localBriefs = home.appendingPathComponent("Market briefs")
}

public struct Level: Equatable, Hashable {
    public var symbol: String
    public var above: Double
    public var below: Double
    public init(symbol: String, above: Double = 0, below: Double = 0) {
        self.symbol = symbol; self.above = above; self.below = below
    }
}

/// watchlist.json. Unknown keys (trading limits, brief_folder, …) are kept untouched on save.
public struct WatchConfig: Equatable {
    public var symbols: [String]
    public var moveAlertPct: Double
    public var levels: [Level]
    public var newsPerSymbol: Int
    var raw: [String: Any] = [:]

    public init(symbols: [String], moveAlertPct: Double, levels: [Level] = [], newsPerSymbol: Int = 2) {
        self.symbols = symbols; self.moveAlertPct = moveAlertPct; self.levels = levels; self.newsPerSymbol = newsPerSymbol
    }

    public static func == (a: WatchConfig, b: WatchConfig) -> Bool {
        a.symbols == b.symbols && a.moveAlertPct == b.moveAlertPct && a.levels == b.levels && a.newsPerSymbol == b.newsPerSymbol
    }

    public static func load(from url: URL = Paths.watchlist) throws -> WatchConfig {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let levels = (raw["levels"] as? [[String: Any]] ?? []).compactMap { d -> Level? in
            guard let s = d["symbol"] as? String else { return nil }
            return Level(symbol: s, above: (d["above"] as? NSNumber)?.doubleValue ?? 0, below: (d["below"] as? NSNumber)?.doubleValue ?? 0)
        }
        var c = WatchConfig(symbols: raw["symbols"] as? [String] ?? ["SPY"],
                            moveAlertPct: (raw["move_alert_pct"] as? NSNumber)?.doubleValue ?? 3,
                            levels: levels,
                            newsPerSymbol: (raw["news_per_symbol"] as? NSNumber)?.intValue ?? 2)
        c.raw = raw
        return c
    }

    public func save(to url: URL = Paths.watchlist) throws {
        var d = raw
        d["symbols"] = symbols
        d["move_alert_pct"] = moveAlertPct
        d["levels"] = levels.map { ["symbol": $0.symbol, "above": $0.above, "below": $0.below] }
        d["news_per_symbol"] = newsPerSymbol
        let data = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

public struct Keys {
    public let id: String
    public let secret: String

    public static func load(from url: URL = Paths.keys) throws -> Keys {
        var d: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            d[String(t[..<eq]).trimmingCharacters(in: .whitespaces)] = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let id = d["ALPACA_KEY_ID"], let s = d["ALPACA_SECRET_KEY"], !id.isEmpty, !s.isEmpty else {
            throw MarketError.message("Alpaca keys missing in \(url.path)")
        }
        return Keys(id: id, secret: s)
    }
}

public enum MarketError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
