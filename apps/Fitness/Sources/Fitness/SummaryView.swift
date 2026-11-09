import Charts
import SwiftUI

struct SummaryView: View {
    let o: Overview
    @Binding var section: Section?
    var t: Overview.Totals { o.totals }

    var body: some View {
        Page {
            StatGrid {
                StatTile("Aktivity", Fmt.int(t.sessions), detail: perWeek(t.sessions, "za týždeň"), symbol: "flame.fill", tint: .orange)
                StatTile("Čas", Fmt.hours((t.hours ?? 0) * 60), detail: perWeek((t.hours ?? 0), "h za týždeň"), symbol: "stopwatch.fill", tint: .blue)
                StatTile("Vzdialenosť", "\(Fmt.one(t.km ?? 0)) km", detail: "zo všetkých športov", symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", tint: .green)
                StatTile("Kalórie", t.avgKcal.map { Fmt.int($0) } ?? "–", detail: kcalDetail, symbol: "fork.knife", tint: .red)
                StatTile("Váha", t.weightKg.map { "\(Fmt.one($0)) kg" } ?? "–", detail: weightDetail, symbol: "scalemass.fill", tint: .purple)
            }

            Card("Čas po týždňoch", subtitle: "podľa športu") { WeeklySportsChart(weeks: o.weekly, sports: o.sports) }

            Card("Športy") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(o.sports) { s in
                        Button { section = .sport(s.sport) } label: { SportTile(s: s) }.buttonStyle(.plain)
                    }
                }
            }

            Card("Posledné aktivity") { ActivityList(items: Array(o.activities.prefix(8))) }
        }
        .navigationTitle("Prehľad")
        .navigationSubtitle("\(Fmt.date(o.period.from)) – \(Fmt.date(o.period.to))")
    }

    func perWeek(_ x: Double, _ unit: String) -> String { "\(Fmt.one(x / max(1, o.period.days / 7))) \(unit)" }
    var kcalDetail: String {
        guard t.loggedDays > 0 else { return "nič zapísané" }
        return t.kcalGoal.map { "priemer · cieľ \(Fmt.int($0))" } ?? "priemer z \(Fmt.int(t.loggedDays)) dní"
    }
    var weightDetail: String {
        if let c = t.weightChangeKg { return "\(Fmt.signed(c, "kg")) za obdobie" }
        return t.weightDate.map { "zapísaná \(Fmt.date($0))" } ?? "nezapísaná"
    }
}

/// A sport on the overview: its symbol, name and the period's numbers. Clicking opens the sport.
struct SportTile: View {
    let s: Overview.SportSummary
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: s.sport.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(s.sport.color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.sport.name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.fill.tertiary.opacity(hover ? 1 : 0.5), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    var detail: String {
        var parts = ["\(Fmt.int(s.sessions)) ×", Fmt.hours(s.minutes)]
        if s.km > 0 { parts.append("\(Fmt.one(s.km)) km") }
        return parts.joined(separator: " · ")
    }
}

/// Hours per week, stacked by sport in the sports' colors; hovering a week shows its breakdown.
struct WeeklySportsChart: View {
    let weeks: [Overview.Week]
    let sports: [Overview.SportSummary]
    @State private var selected: Date?

    struct Item: Identifiable { let week: Date; let sport: Sport; let hours: Double; var id: String { "\(week)\(sport)" } }

    var items: [Item] {
        sports.flatMap { s in s.weekly.filter { $0.minutes > 0 }.map { Item(week: $0.date, sport: s.sport, hours: $0.minutes / 60) } }
    }

    var present: [Sport] { sports.map(\.sport) }

    var body: some View {
        let sel = week(weeks, at: selected) { $0.date }
        Chart {
            ForEach(items) { i in
                BarMark(x: .value("Týždeň", i.week, unit: .weekOfYear), y: .value("Hodiny", i.hours))
                    .foregroundStyle(by: .value("Šport", i.sport.name))
                    .opacity(sel == nil || sel?.date == i.week ? 1 : 0.4)
            }
            if let sel {
                RuleMark(x: .value("Týždeň", sel.date, unit: .weekOfYear))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: Fmt.week(sel.date), lines: ["\(Fmt.hours(sel.minutes)) · \(Fmt.int(sel.sessions)) aktivít"] + (sel.km > 0 ? ["\(Fmt.one(sel.km)) km"] : []))
                    }
            }
        }
        .chartForegroundStyleScale(domain: present.map(\.name), range: present.map(\.color))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
        .chartXAxis { weekAxis(weeks.count) }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(Fmt.int(h)) h") } } } }
        .chartXSelection(value: $selected)
        .frame(height: 220)
    }
}
