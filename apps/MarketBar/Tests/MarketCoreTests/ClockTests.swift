import XCTest
@testable import MarketCore

final class ClockTests: XCTestCase {
    func testParseAndCountdown() throws {
        // Wednesday 2026-11-04, open; closes 16:00 New York = 21:00 UTC
        let c = try XCTUnwrap(Parse.clock(["is_open": true, "next_open": "2026-11-05T09:30:00-05:00", "next_close": "2026-11-04T16:00:00-05:00",
                                           "timestamp": "2026-11-04T14:18:00.123456789-05:00"]))
        let now = ISO8601DateFormatter().date(from: "2026-11-04T19:18:00Z")!   // 14:18 New York
        XCTAssertEqual(c.next.event, "close")
        XCTAssertEqual(c.compact(now), "1:42")
        XCTAssertEqual(c.progress(now)!, (4 * 60 + 48) / 390.0, accuracy: 1e-9)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        XCTAssertEqual(c.status(now, calendar: cal), "US market open · closes in 1h 42m (22:00)")
    }

    func testClosedOverTheWeekend() throws {
        let c = try XCTUnwrap(Parse.clock(["is_open": false, "next_open": "2026-11-09T09:30:00-05:00", "next_close": "2026-11-09T16:00:00-05:00"]))
        let fri = ISO8601DateFormatter().date(from: "2026-11-06T22:00:00Z")!
        XCTAssertNil(c.compact(fri))          // more than a day away: no countdown in the menu bar
        XCTAssertNil(c.progress(fri))
        XCTAssertEqual(MarketClock.span(c.nextOpen.timeIntervalSince(fri)), "2d 16h")
    }

    func testSpans() {
        XCTAssertEqual(MarketClock.span(20), "<1m")
        XCTAssertEqual(MarketClock.span(13 * 60 + 5), "13m")
        XCTAssertEqual(MarketClock.span(-5), "<1m")
    }
}
