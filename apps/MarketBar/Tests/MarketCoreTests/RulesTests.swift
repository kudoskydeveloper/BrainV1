import XCTest
@testable import MarketCore

final class RulesTests: XCTestCase {
    let quotes = ["AAPL": Quote(symbol: "AAPL", last: 208, prev: 200),
                  "MSFT": Quote(symbol: "MSFT", last: 398, prev: 400),
                  "NVDA": Quote(symbol: "NVDA", last: 96, prev: 100)]
    let cfg = WatchConfig(symbols: ["AAPL", "MSFT", "NVDA"], moveAlertPct: 3, levels: [Level(symbol: "MSFT", below: 399)])

    func testAlertsFireOncePerKey() {
        let first = Rules.alerts(quotes, cfg, sent: [])
        XCTAssertEqual(first.map(\.key), ["move:AAPL:up", "move:NVDA:down", "below:MSFT:399.0"])
        XCTAssertEqual(Rules.alerts(quotes, cfg, sent: Set(first.map(\.key))), [])
    }

    func testUnprotectedPositions() {
        let pos = [Position(symbol: "AMD", qty: 10, price: 480, pl: 0, plPct: 0), Position(symbol: "ANET", qty: 27, price: 180, pl: 0, plPct: 0),
                   Position(symbol: "MCD", qty: 17, price: 280, pl: 0, plPct: 0), Position(symbol: "SPY", qty: 2, price: 760, pl: 0, plPct: 0)]
        let orders: [[String: Any]] = [
            ["symbol": "AMD", "status": "filled", "type": "market", "side": "buy", "time_in_force": "day",
             "legs": [["symbol": "AMD", "status": "held", "type": "stop", "side": "sell", "qty": "10", "time_in_force": "day", "stop_price": "471"]]],
            ["symbol": "ANET", "status": "new", "type": "stop", "side": "sell", "qty": "10", "time_in_force": "gtc"],
            ["symbol": "SPY", "status": "new", "type": "trailing_stop", "side": "sell", "qty": "2", "time_in_force": "gtc"],
            ["symbol": "MCD", "status": "expired", "type": "stop", "side": "sell", "qty": "17", "time_in_force": "day"],
        ]
        let alerts = Rules.unprotected(pos, Parse.stopOrders(orders), sent: [])
        XCTAssertEqual(alerts.map(\.key), ["unprotected:AMD:day", "unprotected:ANET:partial", "unprotected:MCD:none"])
        XCTAssertTrue(alerts[0].text.contains("471"))
        XCTAssertEqual(Rules.unprotected(pos, Parse.stopOrders(orders), sent: Set(alerts.map(\.key))), [])
    }

    func testBriefSlots() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        func at(_ s: String) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: Int(s.prefix(2))!, hour: Int(s.dropFirst(3).prefix(2))!, minute: Int(s.suffix(2))!))! }
        XCTAssertEqual(Rules.briefSlot(at("04 08:31"), calendar: cal, done: []), "2026-11-04 08:30")      // Wednesday
        XCTAssertNil(Rules.briefSlot(at("04 08:31"), calendar: cal, done: ["2026-11-04 08:30"]))
        XCTAssertNil(Rules.briefSlot(at("04 08:29"), calendar: cal, done: []))
        XCTAssertNil(Rules.briefSlot(at("04 09:40"), calendar: cal, done: []))                            // over an hour late
        XCTAssertEqual(Rules.briefSlot(at("04 15:20"), calendar: cal, done: []), "2026-11-04 15:15")
        XCTAssertNil(Rules.briefSlot(at("07 08:35"), calendar: cal, done: []))                            // Saturday
    }

    func testParseSnapshotsAndStream() {
        let snap: [String: Any] = ["SPY": ["prevDailyBar": ["c": 750.0], "latestTrade": ["p": 757.5]], "BAD": ["prevDailyBar": [:]]]
        XCTAssertEqual(Parse.snapshots(snap)["SPY"]?.pct ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertNil(Parse.snapshots(snap)["BAD"])
        let msg = Data(#"[{"T":"t","S":"SPY","p":755.1,"s":10},{"T":"q","S":"SPY"},{"T":"error","code":406,"msg":"connection limit exceeded"}]"#.utf8)
        XCTAssertEqual(Parse.streamTrades(msg).map { $0.0 }, ["SPY"])
        XCTAssertEqual(Parse.streamErrors(msg), ["406: connection limit exceeded"])
        XCTAssertFalse(Parse.streamAuthenticated(msg))
        XCTAssertTrue(Parse.streamAuthenticated(Data(#"[{"T":"success","msg":"authenticated"}]"#.utf8)))
    }

    func testLastDayCloses() {
        let bars: [String: [[String: Any]]] = ["SPY": [["t": "2026-11-02T20:45:00Z", "c": 1.0], ["t": "2026-11-03T14:30:00Z", "c": 2.0], ["t": "2026-11-03T14:45:00Z", "c": 3.0]]]
        XCTAssertEqual(Parse.lastDayCloses(bars)["SPY"], [2, 3])
    }

    func testConfigRoundTripKeepsUnknownKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-\(UUID()).json")
        try Data(#"{"symbols":["SPY"],"move_alert_pct":3,"levels":[],"trading":{"max_order_usd":5000}}"#.utf8).write(to: url)
        var c = try WatchConfig.load(from: url)
        c.symbols.append("AMD")
        try c.save(to: url)
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(back["symbols"] as? [String], ["SPY", "AMD"])
        XCTAssertEqual((back["trading"] as? [String: Any])?["max_order_usd"] as? Int, 5000)
    }

    func testBriefMarkdown() {
        let md = Rules.briefMarkdown(day: "2026-11-03", quotes: quotes, account: Account(equity: 101_000, lastEquity: 100_000, cash: 50_000, buyingPower: 0),
                                     positions: [], news: [NewsItem(id: 1, headline: "Apple news", url: "https://x", symbols: ["AAPL"], date: Date())])
        XCTAssertTrue(md.contains("+1000.00, +1.00% today"))
        XCTAssertTrue(md.contains("| AAPL | 208.00 | 200.00 | +4.00% |"))
        XCTAssertTrue(md.contains("[Apple news](https://x)"))
    }
}
