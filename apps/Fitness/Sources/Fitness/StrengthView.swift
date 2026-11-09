import Charts
import SwiftUI

/// Strength training: the period's numbers, sessions and volume per week, every exercise with its progress, and the workouts.
struct StrengthView: View {
    let o: Overview
    @State private var muscle: String? = nil
    @State private var query = ""
    @State private var sort = Sort.sessions
    @State private var showAll = false

    enum Sort: String, CaseIterable, Identifiable {
        case sessions = "Najčastejšie", recent = "Naposledy", name = "Podľa názvu", progress = "Najväčší progres"
        var id: String { rawValue }
    }

    var s: Overview.SportSummary? { o.sport(.strength) }
    var workouts: [Overview.Activity] { o.activities(.strength) }
    var hevyWorkouts: [Overview.Activity] { workouts.filter { $0.source == "hevy" } }

    var body: some View {
        Page {
            StatGrid {
                StatTile("Tréningy", Fmt.int(s?.sessions ?? 0), detail: "\(Fmt.one((s?.sessions ?? 0) / max(1, o.period.days / 7))) za týždeň",
                         symbol: Sport.strength.symbol, tint: .orange)
                StatTile("Čas", Fmt.hours(s?.minutes ?? 0), detail: s.map { "\(Fmt.duration($0.minutes / max(1, $0.sessions))) priemerne" },
                         symbol: "stopwatch.fill", tint: .blue)
                StatTile("Objem", "\(Fmt.int((s?.volumeKg ?? 0) / 1000)) t", detail: "\(hevyWorkouts.count) tréningov v Hevy", symbol: "scalemass.fill", tint: .purple)
                StatTile("Sety", Fmt.int(hevyWorkouts.reduce(0) { $0 + ($1.sets ?? 0) }), detail: "bez rozcvičky", symbol: "square.stack.3d.up.fill", tint: .teal)
            }

            if let last = o.strength.lastHevyWorkout, Fmt.day(last) < Calendar.current.date(byAdding: .day, value: -10, to: .now)! {
                Notice(symbol: "info.circle.fill",
                       text: "Posledný tréning v Hevy bol \(Fmt.date(last)) – novšie silové tréningy sú len na Strave, bez cvikov a váh.",
                       tint: .blue)
            }

            if let s, s.sessions > 0 {
                HStack(alignment: .top, spacing: 16) {
                    Card("Tréningy po týždňoch") { StrengthWeekChart(weeks: s.weekly, volume: false) }
                    Card("Objem po týždňoch", subtitle: "Hevy, kg × opakovania") { StrengthWeekChart(weeks: s.weekly, volume: true) }
                }
            }

            Card("Cviky", subtitle: historyLine) {
                HStack {
                    TextField("Hľadať cvik", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Picker("Partia", selection: $muscle) {
                        Text("Všetky partie").tag(String?.none)
                        Divider()
                        ForEach(muscles, id: \.self) { m in Text(Muscle.name(m)).tag(String?.some(m)) }
                    }
                    .fixedSize()
                    Picker("Zoradiť", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                    Spacer()
                }
                .labelsHidden()
                .controlSize(.regular)

                ExerciseHeader()
                let shown = showAll || !query.isEmpty || muscle != nil ? exercises : Array(exercises.prefix(12))
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        NavigationLink(value: e) { ExerciseRow(e: e) }.buttonStyle(.plain)
                        if i < shown.count - 1 { Divider() }
                    }
                }
                if shown.count < exercises.count || (showAll && exercises.count > 12 && query.isEmpty && muscle == nil) {
                    Button(showAll ? "Zobraziť menej" : "Zobraziť všetky (\(exercises.count))") { withAnimation(.snappy) { showAll.toggle() } }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                }
                if exercises.isEmpty {
                    Text(o.strength.exercises.isEmpty ? "V Hevy za posledný rok nie sú žiadne cviky." : "Nič nezodpovedá filtru.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                }
            }

            Card("Tréningy") {
                if workouts.isEmpty {
                    Text("Za toto obdobie žiadne silové tréningy.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(workouts.enumerated()), id: \.element.id) { i, w in
                            if w.exercises != nil { WorkoutRow(w: w) } else { ActivityRow(a: w) }
                            if i < workouts.count - 1 { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Silový tréning")
        .navigationSubtitle("\(Fmt.date(o.period.from)) – \(Fmt.date(o.period.to))")
    }

    var historyLine: String {
        guard let from = o.strength.historyFrom else { return "z Hevy" }
        return "\(o.strength.exercises.filter { $0.muscle != "cardio" }.count) cvikov z Hevy od \(Fmt.dateYear(Fmt.day(from)))"
    }

    var muscles: [String] {
        Array(Set(o.strength.exercises.compactMap(\.muscle).filter { $0 != "cardio" })).sorted { Muscle.name($0) < Muscle.name($1) }
    }

    var exercises: [Overview.Exercise] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = o.strength.exercises.filter {
            $0.muscle != "cardio" &&   // Running, Cycling… logged in Hevy belong to their sports
            (muscle == nil || $0.muscle == muscle) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || Muscle.name($0.muscle).localizedCaseInsensitiveContains(q))
        }
        switch sort {
        case .sessions: return list
        case .recent: return list.sorted { $0.lastDate > $1.lastDate }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .progress: return list.sorted { ($0.change ?? -.infinity) > ($1.change ?? -.infinity) }
        }
    }
}

struct StrengthWeekChart: View {
    let weeks: [Overview.SportWeek]
    let volume: Bool
    @State private var selected: Date?

    func value(_ w: Overview.SportWeek) -> Double { volume ? w.volumeKg / 1000 : w.sessions }
    func label(_ x: Double) -> String { volume ? "\(Fmt.one(x)) t" : "\(Fmt.int(x)) ×" }

    var body: some View {
        let sel = week(weeks, at: selected) { $0.date }
        Chart {
            ForEach(weeks) { w in
                BarMark(x: .value("Týždeň", w.date, unit: .weekOfYear), y: .value(volume ? "Objem" : "Tréningy", value(w)))
                    .foregroundStyle((volume ? Color.purple : .orange).gradient)
                    .cornerRadius(4)
                    .opacity(sel == nil || sel?.id == w.id ? 1 : 0.4)
            }
            if let sel {
                RuleMark(x: .value("Týždeň", sel.date, unit: .weekOfYear))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartCallout(title: Fmt.week(sel.date), lines: [label(value(sel))])
                    }
            }
        }
        .chartXAxis { weekAxis(weeks.count) }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let x = v.as(Double.self) { Text(label(x)) } } } }
        .chartXSelection(value: $selected)
        .frame(height: 180)
    }
}

// MARK: Exercises

private enum Col { static let sessions: CGFloat = 70, last: CGFloat = 110, best: CGFloat = 110, trend: CGFloat = 120, change: CGFloat = 80 }

struct ExerciseHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Cvik").frame(maxWidth: .infinity, alignment: .leading)
            Text("Tréningy").frame(width: Col.sessions, alignment: .trailing)
            Text("Posledne").frame(width: Col.last, alignment: .trailing)
            Text("Najlepšie").frame(width: Col.best, alignment: .trailing)
            Text("Vývoj").frame(width: Col.trend, alignment: .center)
            Text("Zmena").frame(width: Col.change, alignment: .trailing)
            Color.clear.frame(width: 10)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
}

struct ExerciseRow: View {
    let e: Overview.Exercise
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1)
                Text("\(Muscle.name(e.muscle)) · naposledy \(Fmt.date(e.lastDate))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.int(e.sessions)).frame(width: Col.sessions, alignment: .trailing)
            Text(Fmt.set(e.last)).frame(width: Col.last, alignment: .trailing)
            Text(e.bestE1rmKg.map { "1RM \(Fmt.int($0)) kg" } ?? Fmt.set(e.best)).frame(width: Col.best, alignment: .trailing)
                .help(e.weighted ? "Najlepší odhad maxima na 1 opakovanie (Epley): \(Fmt.set(e.best)), \(Fmt.date(e.bestDate))" : "Najviac opakovaní")
            Sparkline(points: e.history, weighted: e.weighted).frame(width: Col.trend, height: 26)
            Group {
                if let c = e.change, e.history.count > 1 { ChangeBadge(value: c, unit: e.weighted ? "kg" : "op.") } else { Text("–").foregroundStyle(.tertiary) }
            }
            .frame(width: Col.change, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 10)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(.rect)
        .background(.fill.tertiary.opacity(hover ? 1 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// The exercise's estimated 1RM (or reps) over time, small, without axes.
struct Sparkline: View {
    let points: [Overview.ExercisePoint]
    let weighted: Bool
    func v(_ p: Overview.ExercisePoint) -> Double { weighted ? (p.e1rmKg ?? 0) : (p.maxReps ?? 0) }
    var body: some View {
        if points.count < 2 {
            Text("–").foregroundStyle(.tertiary)
        } else {
            let vs = points.map(v), lo = vs.min()!, hi = vs.max()!
            Chart(points) { p in
                LineMark(x: .value("Deň", p.day), y: .value("Hodnota", v(p)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: lo == hi ? (lo - 1)...(hi + 1) : lo...hi)
            .chartLegend(.hidden)
        }
    }
}

/// A Hevy workout that opens to show each exercise and its sets.
struct WorkoutRow: View {
    let w: Overview.Activity
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: Sport.strength.symbol)
                        .font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.orange.gradient, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).lineLimit(1)
                        Text("\(Fmt.weekday(w.when)), \(Fmt.time(w.when)) · Hevy").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if open, let ex = w.exercises {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(ex) { e in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(e.name).font(.callout)
                            Text(e.sets.map { ($0.type == "warmup" ? "R " : "") + Fmt.logged($0) }.joined(separator: "   "))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 52).padding(.trailing, 10).padding(.bottom, 10)
                .transition(.opacity)
            }
        }
    }

    var detail: String {
        var parts: [String] = []
        if let m = w.minutes { parts.append(Fmt.duration(m)) }
        if let n = w.exercises?.count { parts.append("\(n) cvikov") }
        if let s = w.sets { parts.append("\(Fmt.int(s)) setov") }
        if let v = w.volumeKg, v > 0 { parts.append("\(Fmt.int(v)) kg") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: One exercise

struct ExerciseView: View {
    let e: Overview.Exercise
    @State private var metric: Metric
    @State private var selected: Date?

    enum Metric: String, CaseIterable, Identifiable {
        case e1rm = "Odhad 1RM", top = "Najväčšia váha", volume = "Objem", reps = "Opakovania"
        var id: String { rawValue }
    }

    init(e: Overview.Exercise) {
        self.e = e
        _metric = State(initialValue: e.weighted ? .e1rm : .reps)
    }

    var metrics: [Metric] { e.weighted ? [.e1rm, .top, .volume, .reps] : [.reps] }

    func value(_ p: Overview.ExercisePoint) -> Double? {
        switch metric {
        case .e1rm: p.e1rmKg
        case .top: p.topKg
        case .volume: p.volumeKg > 0 ? p.volumeKg : nil
        case .reps: p.maxReps
        }
    }
    func label(_ x: Double) -> String {
        switch metric {
        case .e1rm, .top: "\(Fmt.one(x)) kg"
        case .volume: "\(Fmt.int(x)) kg"
        case .reps: "\(Fmt.int(x)) opak."
        }
    }

    var body: some View {
        Page {
            StatGrid {
                if let b = e.bestE1rmKg {
                    StatTile("Odhad 1RM", "\(Fmt.one(b)) kg", detail: "\(Fmt.set(e.best)), \(Fmt.date(e.bestDate))", symbol: "trophy.fill", tint: .yellow)
                } else {
                    StatTile("Najlepšie", Fmt.set(e.best), detail: Fmt.date(e.bestDate), symbol: "trophy.fill", tint: .yellow)
                }
                StatTile("Posledne", Fmt.set(e.last), detail: Fmt.date(e.lastDate), symbol: "clock.fill", tint: .blue)
                if let top = e.history.compactMap(\.topKg).max() {
                    StatTile("Najväčšia váha", "\(Fmt.one(top)) kg", symbol: "scalemass.fill", tint: .purple)
                }
                StatTile("Tréningy", Fmt.int(e.sessions), detail: "od \(Fmt.date(e.firstDate))", symbol: "calendar", tint: .orange)
                if let c = e.change, e.history.count > 1 {
                    StatTile("Zmena", Fmt.signed(c, e.weighted ? "kg" : "opak."), detail: e.weighted ? "1RM od \(Fmt.date(e.firstDate))" : "od \(Fmt.date(e.firstDate))",
                             symbol: c >= 0 ? "arrow.up.right" : "arrow.down.right", tint: c >= 0 ? .green : .red)
                }
            }

            Card("Vývoj v čase") {
                if metrics.count > 1 {
                    Picker("Ukazovateľ", selection: $metric) { ForEach(metrics) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                chart
                if metric == .e1rm {
                    Text("Odhad maxima na jedno opakovanie z najlepšej série (Epleyho vzorec: váha × (1 + opakovania / 30)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card("História") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Dátum"); Text("Tréning"); Text("Série").gridColumnAlignment(.trailing)
                        Text("Najlepšia séria").gridColumnAlignment(.trailing)
                        if e.weighted { Text("1RM").gridColumnAlignment(.trailing); Text("Objem").gridColumnAlignment(.trailing) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(e.history.reversed()) { p in
                        GridRow {
                            Text(Fmt.weekday(p.day))
                            Text(p.workout).lineLimit(1).foregroundStyle(.secondary)
                            Text(Fmt.int(p.sets))
                            Text(Fmt.set(p.bestSet))
                            if e.weighted {
                                Text(p.e1rmKg.map { "\(Fmt.one($0)) kg" } ?? "–")
                                Text("\(Fmt.int(p.volumeKg)) kg").foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(e.name)
        .navigationSubtitle([Muscle.name(e.muscle), e.equipment.map(equipment)].compactMap { $0 }.joined(separator: " · "))
    }

    @ViewBuilder var chart: some View {
        let pts = e.history.filter { value($0) != nil }
        if pts.isEmpty {
            EmptyChart(text: "Pre tento ukazovateľ nie sú dáta.")
        } else {
            let vs = pts.compactMap(value), lo = vs.min()!, hi = vs.max()!, pad = max(1, (hi - lo) * 0.15)
            let sel = nearest(pts, to: selected) { $0.day }
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Deň", p.day, unit: .day), yStart: .value("Spodok", lo - pad), yEnd: .value(metric.rawValue, value(p)!))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.25), .orange.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Deň", p.day, unit: .day), y: .value(metric.rawValue, value(p)!))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    PointMark(x: .value("Deň", p.day, unit: .day), y: .value(metric.rawValue, value(p)!))
                        .foregroundStyle(.orange)
                        .symbolSize(sel?.id == p.id ? 90 : 24)
                }
                if let sel, let v = value(sel) {
                    RuleMark(x: .value("Deň", sel.day, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartCallout(title: Fmt.dateYear(sel.day), lines: [label(v), Fmt.set(sel.bestSet)])
                        }
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let x = v.as(Double.self) { Text(label(x)) } } } }
            .chartXSelection(value: $selected)
            .frame(height: 260)
        }
    }

    func equipment(_ k: String) -> String {
        ["barbell": "Veľká činka", "dumbbell": "Jednoručky", "machine": "Stroj", "cable": "Kladka", "kettlebell": "Kettlebell",
         "plate": "Kotúč", "resistance_band": "Guma", "suspension": "TRX", "none": "Bez náčinia", "other": "Iné"][k] ?? k
    }
}
