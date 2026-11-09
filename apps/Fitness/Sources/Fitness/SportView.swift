import Charts
import SwiftUI

/// One endurance sport (bicycle, running, swimming, walking, other): its numbers, a weekly chart and every activity.
struct SportView: View {
    let o: Overview
    let sport: Sport
    @State private var metric = Metric.distance

    enum Metric: String, CaseIterable, Identifiable {
        case distance = "Vzdialenosť", time = "Čas", elevation = "Prevýšenie"
        var id: String { rawValue }
    }

    var body: some View {
        let s = o.sport(sport)
        Page {
            if let s {
                StatGrid {
                    StatTile("Aktivity", Fmt.int(s.sessions), detail: "\(Fmt.one(s.sessions / max(1, o.period.days / 7))) za týždeň", symbol: sport.symbol, tint: sport.color)
                    StatTile("Čas", Fmt.hours(s.minutes), detail: "\(Fmt.duration(s.minutes / max(1, s.sessions))) priemerne", symbol: "stopwatch.fill", tint: .blue)
                    if sport.usesDistance {
                        StatTile("Vzdialenosť", "\(Fmt.one(s.km)) km", detail: s.avgKm.map { "\(Fmt.one($0)) km priemerne" }, symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", tint: .green)
                        StatTile(sport == .run || sport == .walk ? "Tempo" : "Rýchlosť", speed(s) ?? "–", detail: "priemer", symbol: "speedometer", tint: .teal)
                    }
                    if s.elevationM > 0 {
                        StatTile("Prevýšenie", "\(Fmt.int(s.elevationM)) m", symbol: "mountain.2.fill", tint: .brown)
                    }
                    if let hr = s.avgHr { StatTile("Tep", "\(Fmt.int(hr)) bpm", detail: "priemer", symbol: "heart.fill", tint: .red) }
                    if let l = s.longest, l.km > 0 {
                        StatTile("Najdlhšia", "\(Fmt.one(l.km)) km", detail: "\(Fmt.date(l.date)) · \(l.title)", symbol: "trophy.fill", tint: .yellow)
                    }
                }

                Card("Po týždňoch") {
                    Picker("Ukazovateľ", selection: $metric) {
                        ForEach(metrics(s)) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    SportWeekChart(weeks: s.weekly, metric: metrics(s).contains(metric) ? metric : .time, color: sport.color)
                }

                Card("Aktivity", subtitle: "Kliknutím otvoríš aktivitu na Strave") { ActivityList(items: o.activities(sport)) }
            } else {
                ContentUnavailableView("Žiadne aktivity", systemImage: sport.symbol,
                                       description: Text("Za toto obdobie tu nie je nič. Skús dlhšie obdobie hore v lište."))
                    .frame(minHeight: 300)
            }
        }
        .navigationTitle(sport.name)
        .navigationSubtitle("\(Fmt.date(o.period.from)) – \(Fmt.date(o.period.to))")
    }

    func metrics(_ s: Overview.SportSummary) -> [Metric] {
        (s.km > 0 ? [.distance] : []) + [.time] + (s.elevationM > 0 ? [.elevation] : [])
    }

    func speed(_ s: Overview.SportSummary) -> String? {
        guard let v = s.avgSpeedKmh, v > 0 else { return nil }
        if sport == .run || sport == .walk {
            let secPerKm = 3600 / v
            return "\(Int(secPerKm) / 60):\(String(format: "%02d", Int(secPerKm) % 60)) /km"
        }
        if sport == .swim { return "\(Fmt.int(6000 / v)) s /100 m" }
        return "\(Fmt.one(v)) km/h"
    }
}

struct SportWeekChart: View {
    let weeks: [Overview.SportWeek]
    let metric: SportView.Metric
    let color: Color
    @State private var selected: Date?

    func value(_ w: Overview.SportWeek) -> Double {
        switch metric {
        case .distance: w.km
        case .time: w.minutes / 60
        case .elevation: w.elevationM
        }
    }
    func label(_ x: Double) -> String {
        switch metric {
        case .distance: "\(Fmt.one(x)) km"
        case .time: Fmt.hours(x * 60)
        case .elevation: "\(Fmt.int(x)) m"
        }
    }

    var body: some View {
        let sel = week(weeks, at: selected) { $0.date }
        Chart {
            ForEach(weeks) { w in
                BarMark(x: .value("Týždeň", w.date, unit: .weekOfYear), y: .value(metric.rawValue, value(w)))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(4)
                    .opacity(sel == nil || sel?.id == w.id ? 1 : 0.4)
            }
            if let sel {
                RuleMark(x: .value("Týždeň", sel.date, unit: .weekOfYear))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: Fmt.week(sel.date), lines: [label(value(sel)), "\(Fmt.int(sel.sessions)) aktivít"])
                    }
            }
        }
        .chartXAxis { weekAxis(weeks.count) }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let x = v.as(Double.self) { Text(label(x)) } } } }
        .chartXSelection(value: $selected)
        .frame(height: 220)
    }
}
