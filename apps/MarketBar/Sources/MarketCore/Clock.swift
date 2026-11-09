import Foundation

/// Alpaca's market clock: open or not, and the next open and close (holidays and early closes included).
public struct MarketClock: Equatable {
    public var isOpen: Bool
    public var nextOpen: Date
    public var nextClose: Date
    public init(isOpen: Bool, nextOpen: Date, nextClose: Date) {
        self.isOpen = isOpen; self.nextOpen = nextOpen; self.nextClose = nextClose
    }

    static let newYork = TimeZone(identifier: "America/New_York")!

    /// 09:30 New York time on the day of the next close: when the current (or next) session opens.
    public var sessionOpen: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        var c = cal.dateComponents([.year, .month, .day], from: nextClose)
        c.hour = 9; c.minute = 30
        return cal.date(from: c) ?? nextClose.addingTimeInterval(-6.5 * 3600)
    }

    /// The next open or close and what it is.
    public var next: (event: String, at: Date) { isOpen ? ("close", nextClose) : ("open", nextOpen) }

    /// Share of today's session gone, 0…1, while open.
    public func progress(_ now: Date) -> Double? {
        guard isOpen else { return nil }
        let span = nextClose.timeIntervalSince(sessionOpen)
        return span > 0 ? min(1, max(0, now.timeIntervalSince(sessionOpen) / span)) : nil
    }

    /// "1h 42m", "13m", "<1m", "2d 3h".
    public static func span(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m / 1440)d \((m % 1440) / 60)h"
    }

    /// Short form for the menu bar: "1:42", "0:13"; nil when the next event is more than a day away.
    public func compact(_ now: Date) -> String? {
        let m = Int(max(0, next.at.timeIntervalSince(now)) / 60)
        return m < 24 * 60 ? String(format: "%d:%02d", m / 60, m % 60) : nil
    }

    /// "US market open · closes in 1h 42m (22:00)" in local time.
    public func status(_ now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(next.at, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        let left = Self.span(next.at.timeIntervalSince(now))
        return isOpen ? "US market open · closes in \(left) (\(f.string(from: nextClose)))"
                      : "US market closed · opens in \(left) (\(f.string(from: nextOpen)))"
    }
}

extension Parse {
    public static func clock(_ d: [String: Any]) -> MarketClock? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let o = (d["next_open"] as? String).flatMap(f.date), let c = (d["next_close"] as? String).flatMap(f.date) else { return nil }
        return MarketClock(isOpen: d["is_open"] as? Bool ?? false, nextOpen: o, nextClose: c)
    }
}
