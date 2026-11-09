import Foundation

/// A chore on a given day, with who it falls to then.
public struct Due: Identifiable, Hashable, Sendable {
    public let task: HomeTask
    /// The day it's for: the day itself, or a day inside the week/month for flexible chores.
    public let day: Day
    public let who: String
    public var id: String { "\(task.id)@\(task.doneDay(day))" }
}

extension Store {
    /// Day tasks on this day, morning first.
    public func dayTasks(on d: Day) -> [Due] {
        tasks.filter { !$0.isFlexible && $0.occurs(on: d) }
            .sorted { (DayPart.allCases.firstIndex(of: $0.part)!, $0.title) < (DayPart.allCases.firstIndex(of: $1.part)!, $1.title) }
            .map { Due(task: $0, day: d, who: $0.who(on: d, members: members)) }
    }

    /// Week- or month-sized chores due in the period around this day.
    public func flexibleTasks(around d: Day, period: Period) -> [Due] {
        tasks.filter { $0.isFlexible && $0.period == period && $0.dueInPeriod(of: d) }
            .sorted { $0.title < $1.title }
            .map { Due(task: $0, day: d, who: $0.who(on: d, members: members)) }
    }

    /// Missed chores still worth doing: one-offs from the last two weeks, flexible chores from the period that just ended.
    public func overdue(today: Day = .today) -> [Due] {
        tasks.compactMap { t -> Due? in
            let missed: Day?
            switch t.repeatRule {
            case .once(let d): missed = d < today && d >= today.adding(days: -14) ? d : nil
            case .window(_, let e): missed = e < today && e >= today.adding(days: -14) ? e : nil
            case .flexible:
                let prev = t.periodStart(today).adding(days: -1)
                missed = t.dueInPeriod(of: prev) && t.periodEnd(prev) >= today.adding(days: -14) ? prev : nil
            default: missed = nil
            }
            guard let missed, !isDone(t, on: missed) else { return nil }
            return Due(task: t, day: missed, who: t.who(on: missed, members: members))
        }
    }

    /// What's still open today: today's day tasks plus this week's and month's flexible ones, plus overdue.
    public func openCount(today: Day = .today) -> Int {
        let all = dayTasks(on: today) + flexibleTasks(around: today, period: .week) + flexibleTasks(around: today, period: .month)
        return all.filter { !isDone($0.task, on: $0.day) }.count + overdue(today: today).count
    }

    /// Ticked-off chores per member over the last `days` days (flexible ones once per period).
    public func fairness(today: Day = .today, days: Int = 30) -> [(name: String, count: Int)] {
        var counts = Dictionary(uniqueKeysWithValues: members.map { ($0, 0) })
        let since = today.adding(days: -days)
        for t in tasks {
            for d in stride(from: since.adding(days: 1), through: today, by: 1) where t.doneDay(d) == d && isDone(t, on: d) {
                let by = doneBy(t, on: d) ?? t.who(on: d, members: members)
                if counts[by] != nil { counts[by]! += 1 }
            }
        }
        return members.map { ($0, counts[$0] ?? 0) }
    }
}

enum Demo {
    static func data() -> HomeData {
        let today = Day.today
        var d = HomeData()
        d.household = HouseholdInfo(id: "demo", name: "Domov", inviteCode: "K7Q2PX",
                                    members: [Member(userId: "a", name: "Ján"), Member(userId: "b", name: "Jana")])
        d.tasks = [
            HomeTask(id: "d-plants", title: "Poliať kvety", who: "Jana", part: .morning, repeatRule: .weekly([1, 4])),
            HomeTask(id: "d-dish", title: "Vyložiť umývačku", who: Who.takeTurns, part: .morning, repeatRule: .daily),
            HomeTask(id: "d-trash", title: "Vyniesť smeti", who: "Ján", part: .evening, repeatRule: .weekly([1, 3, 5])),
            HomeTask(id: "d-cook", title: "Navariť obed na zajtra", who: Who.anyone, part: .evening, repeatRule: .weekly([7])),
            HomeTask(id: "d-bath", title: "Upratať kúpeľňu", who: Who.takeTurns, part: .anytime,
                     repeatRule: .flexible(.week, every: 1, months: [], anchor: PeriodIndex.week(today))),
            HomeTask(id: "d-sheets", title: "Prezliecť posteľ", who: Who.anyone, part: .anytime,
                     repeatRule: .flexible(.week, every: 2, months: [], anchor: PeriodIndex.week(today))),
            HomeTask(id: "d-fridge", title: "Vyčistiť chladničku", who: "Ján", part: .anytime,
                     repeatRule: .flexible(.month, every: 1, months: [], anchor: PeriodIndex.month(today))),
            HomeTask(id: "d-parcel", title: "Vrátiť balík", who: "Jana", part: .anytime, repeatRule: .once(today.adding(days: -2))),
            HomeTask(id: "d-vet", title: "Objednať psa k veterinárovi", who: "Ján", part: .anytime, repeatRule: .once(today.adding(days: 3))),
        ]
        for (id, back, by) in [("d-dish", 1, "Jana"), ("d-dish", 2, "Ján"), ("d-plants", 0, "Jana"), ("d-trash", 2, "Ján"),
                               ("d-dish", 0, "Ján"), ("d-dish", 3, "Jana"), ("d-trash", 4, "Ján")] {
            let day = today.adding(days: -back)
            let c = Completion(taskId: id, day: day, done: true, by: by)
            d.completions[c.key] = c
        }
        d.shopping = ["Mlieko", "Vajcia 10 ks", "Kuracie prsia 1 kg", "Banány", "Toaletný papier", "Paradajky"].map { ShopItem(name: $0) }
            + [ShopItem(name: "Chlieb", done: true), ShopItem(name: "Káva", done: true)]
        return d
    }
}
