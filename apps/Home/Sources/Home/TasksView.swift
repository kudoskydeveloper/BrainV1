import Charts
import HomeCore
import SwiftUI

struct TasksView: View {
    @Environment(Store.self) private var store
    @State private var editing: HomeTask?
    @State private var hovered: String?

    var body: some View {
        let groups = grouped
        Page {
            HStack(alignment: .firstTextBaseline) {
                Text("Úlohy").font(.largeTitle.weight(.semibold))
                Spacer()
                Button { editing = newTask } label: { Label("Nová úloha", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n")
            }

            fairness

            if store.tasks.isEmpty {
                Card("Zatiaľ žiadne úlohy") {
                    EmptyChart(text: "Pridaj prvú: vynášanie smetí, umývačku, upratovanie kúpeľne…")
                }
            }
            ForEach(groups, id: \.title) { g in
                Card(g.title, subtitle: g.subtitle) {
                    Rows(items: g.items) { t in
                        Button { editing = t } label: { TaskRow(task: t) }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Upraviť") { editing = t }
                                Button("Vymazať", role: .destructive) { withAnimation { store.delete(t) } }
                            }
                    }
                }
            }
        }
        .sheet(item: $editing) { t in TaskEditor(task: t, isNew: store.task(t.id) == nil) }
    }

    var newTask: HomeTask { HomeTask(title: "", repeatRule: .weekly([Day.today.weekday])) }

    struct Group { let title: String; let subtitle: String?; let items: [HomeTask] }

    var grouped: [Group] {
        let sorted = store.tasks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        func pick(_ f: (HomeTask) -> Bool) -> [HomeTask] { sorted.filter(f) }
        return [
            Group(title: "Každý deň a v určité dni", subtitle: nil, items: pick {
                if case .daily = $0.repeatRule { return true }; if case .weekly = $0.repeatRule { return true }; return false
            }),
            Group(title: "Raz za týždeň alebo pár týždňov", subtitle: "V ktorýkoľvek deň týždňa", items: pick { $0.period == .week && $0.isFlexible }),
            Group(title: "Raz za mesiac a menej často", subtitle: "Kedykoľvek v mesiaci", items: pick { $0.period == .month && $0.isFlexible }),
            Group(title: "Jednorazové", subtitle: nil, items: pick { if case .once = $0.repeatRule { return true }; return false }),
        ].filter { !$0.items.isEmpty }
    }

    @ViewBuilder var fairness: some View {
        let f = store.fairness()
        if f.count > 1 {
            Card("Kto čo spravil", subtitle: "Odškrtnuté úlohy za posledných 30 dní") {
                Chart(f, id: \.name) { m in
                    BarMark(x: .value("Úlohy", m.count), y: .value("Člen", m.name))
                        .foregroundStyle(WhoBadge.color(m.name).gradient)
                        .cornerRadius(5)
                        .annotation(position: .trailing) {
                            Text("\(m.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(f.count) * 34)
            }
        }
    }
}

struct TaskRow: View {
    let task: HomeTask
    var body: some View {
        HoverRow {
            Image(systemName: task.part.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                Text("\(task.repeatTitle) · \(task.part.title) · \(Who.title(task.who))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            WhoBadge(who: task.who)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
    var color: Color {
        switch task.part {
        case .morning: .orange
        case .afternoon: .yellow
        case .evening: .indigo
        case .anytime: .teal
        }
    }
}

/// New or existing chore: title, who, part of the day and how often.
struct TaskEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var task: HomeTask
    let isNew: Bool

    enum Kind: String, CaseIterable { case once, daily, weekdays, weeks, months, window
        var title: String {
            switch self {
            case .once: "Raz, v určitý deň"
            case .daily: "Každý deň"
            case .weekdays: "V určité dni týždňa"
            case .weeks: "Raz za týždeň (v ktorýkoľvek deň)"
            case .months: "Raz za mesiac (kedykoľvek)"
            case .window: "Raz, niekedy medzi dvoma dňami"
            }
        }
    }

    @State private var kind = Kind.weekdays
    @State private var date = Date.now
    @State private var end = Date.now.addingTimeInterval(7 * 86400)
    @State private var weekdays: Set<Int> = []
    @State private var every = 1
    @State private var months: Set<Int> = []

    init(task: HomeTask, isNew: Bool) {
        _task = State(initialValue: task)
        self.isNew = isNew
        switch task.repeatRule {
        case .once(let d): _kind = State(initialValue: .once); _date = State(initialValue: d.date)
        case .daily: _kind = State(initialValue: .daily)
        case .weekly(let days): _kind = State(initialValue: .weekdays); _weekdays = State(initialValue: days)
        case let .flexible(p, e, m, _):
            _kind = State(initialValue: p == .week ? .weeks : .months); _every = State(initialValue: e); _months = State(initialValue: m)
        case let .window(s, e): _kind = State(initialValue: .window); _date = State(initialValue: s.date); _end = State(initialValue: e.date)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Názov", text: $task.title, prompt: Text("Napr. Vyniesť smeti"))
                Picker("Kto", selection: $task.who) {
                    ForEach(store.members, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text(Who.title(Who.anyone)).tag(Who.anyone)
                    Text(Who.title(Who.takeTurns)).tag(Who.takeTurns)
                }
                Picker("Kedy cez deň", selection: $task.part) {
                    ForEach(DayPart.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Ako často", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch kind {
                case .once:
                    DatePicker("Deň", selection: $date, displayedComponents: .date)
                case .daily:
                    EmptyView()
                case .weekdays:
                    LabeledContent("Dni") {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { d in
                                Toggle(Fmt.weekdayShort[d - 1], isOn: Binding(get: { weekdays.contains(d) },
                                                                             set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                case .weeks:
                    Stepper(every == 1 ? "Každý týždeň" : "Každé \(every) týždne", value: $every, in: 1...8)
                case .months:
                    Stepper(every == 1 ? "Každý mesiac" : "Každé \(every) mesiace", value: $every, in: 1...12)
                        .disabled(!months.isEmpty)
                    LabeledContent("Len v mesiacoch") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 6), spacing: 4) {
                            ForEach(1...12, id: \.self) { m in
                                Toggle(Fmt.monthShort[m - 1], isOn: Binding(get: { months.contains(m) },
                                                                           set: { if $0 { months.insert(m) } else { months.remove(m) } }))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                case .window:
                    DatePicker("Od", selection: $date, displayedComponents: .date)
                    DatePicker("Do", selection: $end, in: date..., displayedComponents: .date)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Vymazať", role: .destructive) { store.delete(task); dismiss() }
                }
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Pridať" : "Uložiť") { store.save(built); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .weekdays && weekdays.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    var built: HomeTask {
        var t = task
        let today = Day.today
        // Keep the original anchor when only the title or who changed, so "every 2 weeks" doesn't shift.
        func anchor(_ p: Period) -> Int? {
            if case let .flexible(old, _, _, a) = task.repeatRule, old == p { return a }
            return nil
        }
        switch kind {
        case .once: t.repeatRule = .once(Day(date))
        case .daily: t.repeatRule = .daily
        case .weekdays: t.repeatRule = .weekly(weekdays)
        case .weeks: t.repeatRule = .flexible(.week, every: every, months: [], anchor: anchor(.week) ?? PeriodIndex.week(today))
        case .months: t.repeatRule = .flexible(.month, every: months.isEmpty ? every : 1, months: months, anchor: anchor(.month) ?? PeriodIndex.month(today))
        case .window: t.repeatRule = .window(Day(date), max(Day(date), Day(end)))
        }
        return t
    }
}
