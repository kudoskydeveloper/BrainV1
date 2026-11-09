import HomeCore
import SwiftUI

struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(Events.self) private var events
    @Environment(AppState.self) private var app
    var today = Day.today

    var body: some View {
        let day = store.dayTasks(on: today)
        let week = store.flexibleTasks(around: today, period: .week)
        let month = store.flexibleTasks(around: today, period: .month)
        let overdue = store.overdue(today: today)
        let plans = events.on(today)
        let toBuy = store.shopping.filter { !$0.done }

        Page {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.weekday(today)).font(.largeTitle.weight(.semibold))
                Text(greeting).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            StatGrid {
                StatTile("Dnes zostáva", "\(open(day) + open(overdue))", detail: "z \(day.count + overdue.count) úloh na dnes",
                         symbol: "checklist", tint: .blue)
                StatTile("Tento týždeň", "\(week.count - open(week))/\(week.count)", detail: "týždenné úlohy hotové",
                         symbol: "calendar.badge.checkmark", tint: .teal)
                StatTile("Nákup", "\(toBuy.count)", detail: toBuy.first.map { "napr. \($0.name)" } ?? "nič netreba",
                         symbol: "cart.fill", tint: .green)
                StatTile("Plány dnes", "\(plans.count)", detail: plans.first.map(\.title) ?? "voľný deň",
                         symbol: "calendar", tint: .red)
            }

            if !overdue.isEmpty {
                Card("Meškajú", subtitle: "Ešte sa oplatí spraviť") {
                    Rows(items: overdue) { ChoreRow(due: $0, note: Fmt.relative($0.day, today: today)) }
                }
            }

            ForEach(DayPart.allCases, id: \.self) { part in
                let items = day.filter { $0.task.part == part }
                if !items.isEmpty {
                    Card(part.title) { Rows(items: items) { ChoreRow(due: $0) } }
                }
            }

            if day.isEmpty && overdue.isEmpty {
                Card("Na dnes") {
                    Text("Dnes nie sú žiadne denné úlohy.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                if !week.isEmpty {
                    Card("Tento týždeň", subtitle: "\(Fmt.date(today.weekStart)) – \(Fmt.date(today.weekStart.adding(days: 6))), v ktorýkoľvek deň") {
                        Rows(items: week) { ChoreRow(due: $0) }
                    }
                }
                if !month.isEmpty {
                    Card("Tento mesiac", subtitle: "do \(Fmt.date(today.monthEnd))") {
                        Rows(items: month) { ChoreRow(due: $0) }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card("V kalendári", subtitle: events.access == .denied ? "Home nemá prístup ku kalendárom" : nil) {
                    if events.access == .denied {
                        Button("Povoliť v Nastaveniach") { Events.openPrivacySettings() }
                    } else if plans.isEmpty {
                        Text("Dnes nič.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50)
                    } else {
                        Rows(items: plans, inset: 18) { EventRow(event: $0) }
                    }
                }
                Card("Kúpiť", subtitle: toBuy.isEmpty ? nil : "\(toBuy.count) položiek") {
                    if toBuy.isEmpty {
                        Text("Zoznam je prázdny.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50)
                    } else {
                        Rows(items: Array(toBuy.prefix(6))) { ShopRow(item: $0) }
                        if toBuy.count > 6 {
                            Button("Celý zoznam (\(toBuy.count))") { app.section = .shopping }.buttonStyle(.link).padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    func open(_ items: [Due]) -> Int { items.filter { !store.isDone($0.task, on: $0.day) }.count }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        let name = store.me.map { ", \($0)" } ?? ""
        switch h {
        case 5..<10: return "Dobré ráno\(name)."
        case 10..<18: return "Pekný deň\(name)."
        default: return "Dobrý večer\(name)."
        }
    }
}

/// One chore with its tick: title, how often, who; who ticked it off once done.
struct ChoreRow: View {
    @Environment(Store.self) private var store
    let due: Due
    var note: String?

    var body: some View {
        let done = store.isDone(due.task, on: due.day)
        HoverRow {
            CheckButton(done: done) { withAnimation(.snappy) { store.setDone(due.task, on: due.day, !done) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(due.task.title)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                Text(subtitle(done)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            WhoBadge(who: due.who)
        }
    }

    func subtitle(_ done: Bool) -> String {
        var parts = [note ?? due.task.repeatTitle]
        if done, let by = store.doneBy(due.task, on: due.day) { parts.append("spravil(a) \(by)") } else { parts.append(Who.title(due.who)) }
        return parts.joined(separator: " · ")
    }
}

struct EventRow: View {
    let event: Events.Event
    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(event.color).frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1)
                Text(event.allDay ? "Celý deň · \(event.calendar)"
                     : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }
}
