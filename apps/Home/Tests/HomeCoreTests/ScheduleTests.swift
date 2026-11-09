import Foundation
import Testing
@testable import HomeCore

struct ScheduleTests {
    @Test func repeatJSONMatchesTheAndroidShape() throws {
        let rule = Repeat.flexible(.month, every: 1, months: [10], anchor: 24321)
        let json = String(data: try JSONEncoder.iso.encode(rule), encoding: .utf8)!
        #expect(json == #"{"anchor":24321,"every":1,"months":["OCTOBER"],"period":"Month","type":"flexible"}"#)
        let weekly = try JSONDecoder.iso.decode(Repeat.self, from: Data(#"{"type":"weekly","days":["MONDAY","FRIDAY"]}"#.utf8))
        #expect(weekly == .weekly([1, 5]))
    }

    @Test func daysAndPeriods() {
        let d = Day("2026-11-08")!          // a Sunday
        #expect(d.weekday == 7)
        #expect(d.weekStart == Day("2026-11-02")!)
        #expect(d.monthEnd == Day("2026-11-30")!)
        #expect(PeriodIndex.week(Day("2024-01-08")!) == 1)
        #expect(PeriodIndex.month(d) == 2026 * 12 + 10)
    }

    @Test func everyOtherWeekCountsFromItsAnchor() {
        let start = Day("2026-11-02")!
        let t = HomeTask(title: "Posteľ", repeatRule: .flexible(.week, every: 2, months: [], anchor: PeriodIndex.week(start)))
        #expect(t.dueInPeriod(of: start.adding(days: 3)))
        #expect(!t.dueInPeriod(of: start.adding(days: 7)))
        #expect(t.dueInPeriod(of: start.adding(days: 14)))
        #expect(t.doneDay(start.adding(days: 4)) == start)
    }

    @Test func takeTurnsAlternatesByWeek() {
        let t = HomeTask(id: "dish", title: "Umývačka", who: Who.takeTurns, repeatRule: .daily)
        let a = t.who(on: Day("2026-11-03")!, members: ["Ján", "Jana"])
        let b = t.who(on: Day("2026-11-10")!, members: ["Ján", "Jana"])
        #expect(a != b)
        #expect(t.who(on: Day("2026-11-04")!, members: ["Ján", "Jana"]) == a)
    }

    @Test func javaHashMatchesKotlin() {
        #expect(Ids.javaHash("hello") == 99162322)
    }

    @MainActor @Test func demoAgenda() {
        let s = Store(demo: ())
        #expect(!s.dayTasks(on: .today).isEmpty)
        #expect(s.overdue().contains { $0.task.id == "d-parcel" })
        #expect(s.fairness().count == 2)
    }
}
