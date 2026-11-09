import Foundation

/// Part of the day a chore belongs to. Raw values are what Supabase stores.
public enum DayPart: String, Codable, CaseIterable, Sendable {
    case morning = "Morning", afternoon = "Afternoon", evening = "Evening", anytime = "Anytime"

    public var title: String {
        switch self {
        case .morning: "Ráno"
        case .afternoon: "Poobede"
        case .evening: "Večer"
        case .anytime: "Kedykoľvek"
        }
    }
    public var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        case .anytime: "clock"
        }
    }
}

public enum Period: String, Codable, Sendable { case week = "Week", month = "Month" }

/// How often a chore comes back. The JSON shape is the one in the `repeat` column (shared with the old Android panel).
public enum Repeat: Hashable, Sendable {
    case once(Day)
    case daily
    /// Weekdays 1 = Monday … 7 = Sunday.
    case weekly(Set<Int>)
    /// Any day within each week or month, every `every` periods counted from `anchor` (a `PeriodIndex`), optionally only in
    /// some months (1…12, "every October").
    case flexible(Period, every: Int, months: Set<Int>, anchor: Int)
    /// One-off, any day from `start` to `end` ("sometime in October").
    case window(Day, Day)
}

extension Repeat: Codable {
    static let weekdays = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
    static let months = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER",
                         "NOVEMBER", "DECEMBER"]
    enum Key: String, CodingKey { case type, date, days, period, every, months, anchor, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "once": self = .once(try c.decode(Day.self, forKey: .date))
        case "daily": self = .daily
        case "weekly":
            let names = try c.decodeIfPresent([String].self, forKey: .days) ?? []
            self = .weekly(Set(names.compactMap { Repeat.weekdays.firstIndex(of: $0).map { $0 + 1 } }))
        case "flexible":
            let months = try c.decodeIfPresent([String].self, forKey: .months) ?? []
            self = .flexible(try c.decode(Period.self, forKey: .period),
                             every: try c.decodeIfPresent(Int.self, forKey: .every) ?? 1,
                             months: Set(months.compactMap { Repeat.months.firstIndex(of: $0).map { $0 + 1 } }),
                             anchor: try c.decodeIfPresent(Int.self, forKey: .anchor) ?? 0)
        case "window": self = .window(try c.decode(Day.self, forKey: .start), try c.decode(Day.self, forKey: .end))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown repeat \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .once(let d): try c.encode("once", forKey: .type); try c.encode(d, forKey: .date)
        case .daily: try c.encode("daily", forKey: .type)
        case .weekly(let days):
            try c.encode("weekly", forKey: .type)
            try c.encode(days.sorted().map { Repeat.weekdays[$0 - 1] }, forKey: .days)
        case let .flexible(period, every, months, anchor):
            try c.encode("flexible", forKey: .type)
            try c.encode(period, forKey: .period)
            try c.encode(every, forKey: .every)
            try c.encode(months.sorted().map { Repeat.months[$0 - 1] }, forKey: .months)
            try c.encode(anchor, forKey: .anchor)
        case let .window(s, e): try c.encode("window", forKey: .type); try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
        }
    }
}

/// A chore or one-off task. `who` is a member's name, `Who.anyone` or `Who.takeTurns`.
public struct HomeTask: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var who: String
    public var part: DayPart
    public var repeatRule: Repeat

    public init(id: String = Ids.new(), title: String, who: String = Who.anyone, part: DayPart = .anytime, repeatRule: Repeat) {
        self.id = id; self.title = title; self.who = who; self.part = part; self.repeatRule = repeatRule
    }

    enum CodingKeys: String, CodingKey { case id, title, who, part, repeatRule = "repeat" }
}

public enum Who {
    public static let anyone = "Anyone"
    public static let takeTurns = "Take turns"
    public static func title(_ who: String) -> String {
        switch who {
        case anyone: "Ktokoľvek"
        case takeTurns: "Striedame sa"
        default: who
        }
    }
}

public struct ShopItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var done: Bool
    public init(id: String = Ids.new(), name: String, done: Bool = false) { self.id = id; self.name = name; self.done = done }
}

public struct Member: Hashable, Codable, Sendable {
    public var userId: String
    public var name: String
}

public struct HouseholdInfo: Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var inviteCode: String
    public var members: [Member]
}

public enum Ids {
    /// Short random ids, like the Android panel's.
    public static func new() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }
}

// MARK: Schedule

extension HomeTask {
    /// Chores that belong to a week or month (or a one-off window) rather than to one day.
    public var isFlexible: Bool {
        switch repeatRule { case .flexible, .window: true; default: false }
    }

    public var period: Period? {
        switch repeatRule {
        case .flexible(let p, _, _, _): p
        case let .window(s, e): s.days(to: e) <= 7 ? .week : .month
        default: nil
        }
    }

    /// Day tasks: does it fall on this day?
    public func occurs(on d: Day) -> Bool {
        switch repeatRule {
        case .once(let day): day == d
        case .daily: true
        case .weekly(let days): days.contains(d.weekday)
        case .flexible, .window: false
        }
    }

    public func periodStart(_ d: Day) -> Day {
        switch repeatRule {
        case .window(let s, _): s
        case .flexible(let p, _, _, _): p == .week ? d.weekStart : d.monthStart
        default: d
        }
    }

    public func periodEnd(_ d: Day) -> Day {
        switch repeatRule {
        case .window(_, let e): e
        case .flexible(let p, _, _, _): p == .week ? d.weekStart.adding(days: 6) : d.monthEnd
        default: d
        }
    }

    /// Flexible chores: is it due in the week/month that contains this day?
    public func dueInPeriod(of d: Day) -> Bool {
        switch repeatRule {
        case let .window(s, e): return (s...e).contains(d)
        case let .flexible(p, every, months, anchor):
            let idx = p == .week ? PeriodIndex.week(d) : PeriodIndex.month(d)
            let n = max(every, 1)
            return ((idx - anchor) % n + n) % n == 0 && (months.isEmpty || months.contains(d.month))
        default: return false
        }
    }

    /// The day a completion is stored under: the day itself, or the first day of the period for flexible chores.
    public func doneDay(_ d: Day) -> Day { isFlexible ? periodStart(d) : d }

    /// Who it falls to on this day. "Take turns" alternates between members week by week (month by month for monthly chores).
    public func who(on d: Day, members: [String]) -> String {
        guard who == Who.takeTurns, !members.isEmpty else { return who }
        let idx = period == .month ? PeriodIndex.month(periodStart(d)) : d.isoWeek
        return members[(idx + abs(Int(Ids.javaHash(id)))) % members.count]
    }

    /// "Každý deň", "Po, St, Pi", "Raz za 2 týždne", "8. nov" …
    public var repeatTitle: String {
        switch repeatRule {
        case .once(let d): return Fmt.date(d)
        case .daily: return "Každý deň"
        case .weekly(let days):
            if days.count == 7 { return "Každý deň" }
            if days == [1, 2, 3, 4, 5] { return "Pracovné dni" }
            if days == [6, 7] { return "Víkendy" }
            return days.sorted().map { Fmt.weekdayShort[$0 - 1] }.joined(separator: ", ")
        case let .flexible(p, every, months, _):
            let base = switch (p, every) {
            case (.week, 1): "Raz za týždeň"
            case (.week, let n): "Raz za \(n) týždne"
            case (.month, 1): "Raz za mesiac"
            case (.month, let n): "Raz za \(n) mesiace"
            }
            return months.isEmpty ? base : base + " (" + months.sorted().map { Fmt.monthShort[$0 - 1] }.joined(separator: ", ") + ")"
        case let .window(s, e): return "\(Fmt.date(s)) – \(Fmt.date(e))"
        }
    }
}

extension Ids {
    /// Java's String.hashCode, so "take turns" splits chores the same way on every device.
    static func javaHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }
}

public enum Fmt {
    public static let sk = Locale(identifier: "sk_SK")
    public static let weekdayShort = ["Po", "Ut", "St", "Št", "Pi", "So", "Ne"]
    public static let weekdayLong = ["Pondelok", "Utorok", "Streda", "Štvrtok", "Piatok", "Sobota", "Nedeľa"]
    public static let monthShort = ["jan", "feb", "mar", "apr", "máj", "jún", "júl", "aug", "sep", "okt", "nov", "dec"]

    public static func date(_ d: Day) -> String { "\(d.day). \(monthShort[d.month - 1])" }
    public static func weekday(_ d: Day) -> String { "\(weekdayLong[d.weekday - 1]), \(date(d))" }
    public static func relative(_ d: Day, today: Day = .today) -> String {
        switch today.days(to: d) {
        case 0: "Dnes"
        case 1: "Zajtra"
        case -1: "Včera"
        default: weekday(d)
        }
    }
}
