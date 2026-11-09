import Foundation

/// A calendar day without a time ("2026-11-08"), in the Mac's time zone. Chores, completions and periods are all days.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    static var cal: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }

    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    public init(_ date: Date = .now) {
        let c = Day.cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init?(_ s: String) {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        self.init(year: p[0], month: p[1], day: p[2])
    }

    public static var today: Day { Day() }

    /// Noon of the day, so adding days never trips over a daylight-saving change.
    public var date: Date { Day.cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
    public var startOfDay: Date { Day.cal.startOfDay(for: date) }

    public func adding(days n: Int) -> Day { Day(Day.cal.date(byAdding: .day, value: n, to: date)!) }
    public func adding(months n: Int) -> Day { Day(Day.cal.date(byAdding: .month, value: n, to: date)!) }
    public func days(to other: Day) -> Int { Day.cal.dateComponents([.day], from: date, to: other.date).day ?? 0 }

    /// 1 = Monday … 7 = Sunday.
    public var weekday: Int { (Day.cal.component(.weekday, from: date) + 5) % 7 + 1 }
    public var weekStart: Day { adding(days: -(weekday - 1)) }
    public var monthStart: Day { Day(year: year, month: month, day: 1) }
    public var monthEnd: Day { monthStart.adding(months: 1).adding(days: -1) }
    public var isoWeek: Int { Day.cal.component(.weekOfYear, from: date) }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day \(s)")) }
        self = d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension Day: Strideable {
    public func distance(to other: Day) -> Int { days(to: other) }
    public func advanced(by n: Int) -> Day { adding(days: n) }
}

/// Week and month numbers that flexible chores count "every n weeks/months" from (same numbering the Android panel used).
public enum PeriodIndex {
    static let epochMonday = Day(year: 2024, month: 1, day: 1)
    public static func week(_ d: Day) -> Int { Int((Double(epochMonday.days(to: d.weekStart)) / 7).rounded()) }
    public static func month(_ d: Day) -> Int { d.year * 12 + d.month - 1 }
}
