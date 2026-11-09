import Charts
import SwiftUI

/// Food from MyFitnessPal: averages, calories per day against the goal, macros per day and today.
struct NutritionView: View {
    let o: Overview
    var days: [Overview.Day] { o.nutrition.daily }
    var goal: Double? { o.nutrition.goalKcal }

    var body: some View {
        Page {
            StatGrid {
                StatTile("Kalórie", avg(\.kcal).map { Fmt.int($0) } ?? "–", detail: goal.map { "priemer · cieľ \(Fmt.int($0))" } ?? "priemer", symbol: "flame.fill", tint: .orange)
                StatTile("Bielkoviny", avg(\.protein).map { "\(Fmt.int($0)) g" } ?? "–", detail: "priemer za deň", symbol: "fish.fill", tint: .pink)
                StatTile("Sacharidy", avg(\.carbs).map { "\(Fmt.int($0)) g" } ?? "–", detail: "priemer za deň", symbol: "leaf.fill", tint: .blue)
                StatTile("Tuky", avg(\.fat).map { "\(Fmt.int($0)) g" } ?? "–", detail: "priemer za deň", symbol: "drop.fill", tint: .yellow)
                StatTile("Zapísané dni", "\(days.count) z \(Fmt.int(o.period.days))", symbol: "calendar", tint: .green)
            }

            if let t = o.nutrition.today, (t.calories ?? 0) > 0 { TodayCard(t: t) }

            Card("Kalórie za deň", subtitle: goal.map { "čiarkovaná čiara je cieľ \(Fmt.int($0)) kcal" }) {
                if days.isEmpty { EmptyChart(text: "V MyFitnessPal nie je za toto obdobie nič zapísané.") } else { CaloriesChart(days: days, goal: goal) }
            }
            Card("Makrá za deň", subtitle: "gramy") {
                if days.isEmpty { EmptyChart(text: "V MyFitnessPal nie je za toto obdobie nič zapísané.") } else { MacrosChart(days: days) }
            }
        }
        .navigationTitle("Výživa")
        .navigationSubtitle("MyFitnessPal · \(Fmt.date(o.period.from)) – \(Fmt.date(o.period.to))")
    }

    func avg(_ k: KeyPath<Overview.Day, Double?>) -> Double? {
        let xs = days.compactMap { $0[keyPath: k] }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}

struct TodayCard: View {
    let t: Overview.Today
    var body: some View {
        Card("Dnes") {
            HStack(spacing: 24) {
                Ring(value: t.calories ?? 0, goal: t.goalCalories, color: .orange, title: "Kalórie", unit: "kcal")
                Macro(name: "Bielkoviny", value: t.protein, color: .pink)
                Macro(name: "Sacharidy", value: t.carbs, color: .blue)
                Macro(name: "Tuky", value: t.fat, color: .yellow)
            }
        }
    }
}

/// Calories against the goal as an activity-style ring.
struct Ring: View {
    let value: Double, goal: Double?, color: Color, title: String, unit: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 8)
                Circle().trim(from: 0, to: min(1, value / max(1, goal ?? value)))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("\(Fmt.int(value)) \(unit)").font(.headline).monospacedDigit()
                if let goal { Text("zostáva \(Fmt.int(max(0, goal - value)))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Macro: View {
    let name: String, value: Double?, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text("\(Fmt.int(value ?? 0)) g").font(.headline).monospacedDigit()
            Capsule().fill(color.gradient).frame(width: 36, height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CaloriesChart: View {
    let days: [Overview.Day]
    let goal: Double?
    @State private var selected: Date?

    var body: some View {
        let sel = nearest(days, to: selected) { $0.date }
        Chart {
            ForEach(days) { d in
                BarMark(x: .value("Deň", d.date, unit: .day), y: .value("kcal", d.kcal ?? 0))
                    .foregroundStyle((goal.map { (d.kcal ?? 0) > $0 } ?? false ? Color.red : .orange).gradient)
                    .cornerRadius(3)
                    .opacity(sel == nil || sel?.id == d.id ? 1 : 0.4)
            }
            if let goal {
                RuleMark(y: .value("Cieľ", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            if let sel {
                RuleMark(x: .value("Deň", sel.date, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: Fmt.weekday(sel.date), lines: ["\(Fmt.int(sel.kcal ?? 0)) kcal",
                            "B \(Fmt.int(sel.protein ?? 0)) · S \(Fmt.int(sel.carbs ?? 0)) · T \(Fmt.int(sel.fat ?? 0)) g"])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: 220)
    }
}

struct MacrosChart: View {
    let days: [Overview.Day]
    struct Item: Identifiable { let date: Date; let name: String; let grams: Double; var id: String { "\(date)\(name)" } }
    var items: [Item] {
        days.flatMap { d in [("Bielkoviny", d.protein), ("Sacharidy", d.carbs), ("Tuky", d.fat)].compactMap { n, g in g.map { Item(date: d.date, name: n, grams: $0) } } }
    }
    var body: some View {
        Chart(items) { i in
            BarMark(x: .value("Deň", i.date, unit: .day), y: .value("g", i.grams))
                .foregroundStyle(by: .value("Makro", i.name))
        }
        .chartForegroundStyleScale(["Bielkoviny": Color.pink, "Sacharidy": Color.blue, "Tuky": Color.yellow])
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }
}

/// Body weight from Hevy and MyFitnessPal.
struct WeightView: View {
    let o: Overview
    @State private var selected: Date?

    var body: some View {
        let pts = o.weight
        Page {
            StatGrid {
                StatTile("Váha", o.totals.weightKg.map { "\(Fmt.one($0)) kg" } ?? "–", detail: o.totals.weightDate.map { "zapísaná \(Fmt.date($0))" },
                         symbol: "scalemass.fill", tint: .purple)
                if let c = o.totals.weightChangeKg {
                    StatTile("Zmena", Fmt.signed(c, "kg"), detail: "za obdobie", symbol: c <= 0 ? "arrow.down.right" : "arrow.up.right", tint: c <= 0 ? .green : .orange)
                }
                StatTile("Váženia", "\(pts.count)", detail: "za obdobie", symbol: "calendar", tint: .blue)
            }
            Card("Vývoj") {
                if pts.count < 2 {
                    EmptyChart(text: pts.isEmpty ? "Za toto obdobie nie je zapísaná váha." : "Na graf treba aspoň dve váženia. Zapíš váhu v Hevy alebo MyFitnessPal, prípadne zvoľ dlhšie obdobie.")
                } else {
                    let ks = pts.map(\.kg), lo = ks.min()!, hi = ks.max()!
                    let sel = nearest(pts, to: selected) { $0.date }
                    Chart {
                        ForEach(pts) { p in
                            LineMark(x: .value("Deň", p.date, unit: .day), y: .value("kg", p.kg))
                                .interpolationMethod(.monotone).foregroundStyle(.purple).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            PointMark(x: .value("Deň", p.date, unit: .day), y: .value("kg", p.kg)).foregroundStyle(.purple)
                                .symbolSize(sel?.id == p.id ? 90 : 24)
                        }
                        if let sel {
                            RuleMark(x: .value("Deň", sel.date, unit: .day)).foregroundStyle(.secondary.opacity(0.4))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    ChartCallout(title: Fmt.dateYear(sel.date), lines: ["\(Fmt.one(sel.kg)) kg"])
                                }
                        }
                    }
                    .chartYScale(domain: (lo - 1)...(hi + 1))
                    .chartXSelection(value: $selected)
                    .frame(height: 260)
                }
            }
            if !pts.isEmpty {
                Card("Váženia") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        ForEach(pts.reversed()) { p in
                            GridRow {
                                Text(Fmt.weekday(p.date))
                                Text("\(Fmt.one(p.kg)) kg").monospacedDigit().gridColumnAlignment(.trailing)
                                Text(p.source == "hevy" ? "Hevy" : "MyFitnessPal").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Váha")
        .navigationSubtitle("\(Fmt.date(o.period.from)) – \(Fmt.date(o.period.to))")
    }
}
