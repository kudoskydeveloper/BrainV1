#if os(iOS)
import HomeCore
import SwiftUI

// MARK: Dnes

struct TodayTab: View {
    @Environment(Store.self) private var store
    @Environment(MobileCalendar.self) private var calendar
    var today = Day.today

    var body: some View {
        let day = store.dayTasks(on: today)
        let week = store.flexibleTasks(around: today, period: .week)
        let month = store.flexibleTasks(around: today, period: .month)
        let overdue = store.overdue(today: today)
        let plans = calendar.on(today)
        let toBuy = store.shopping.filter { !$0.done }
        List {
            if !overdue.isEmpty {
                Section("Meškajú") { ForEach(overdue) { ChoreRow(due: $0, note: Fmt.relative($0.day, today: today)) } }
            }
            ForEach(DayPart.allCases, id: \.self) { part in
                let items = day.filter { $0.task.part == part }
                if !items.isEmpty {
                    Section { ForEach(items) { ChoreRow(due: $0) } } header: { Label(part.title, systemImage: part.symbol) }
                }
            }
            if !week.isEmpty {
                Section { ForEach(week) { ChoreRow(due: $0) } } header: { Text("Tento týždeň") } footer: { Text("V ktorýkoľvek deň do \(Fmt.date(today.weekStart.adding(days: 6)))") }
            }
            if !month.isEmpty {
                Section { ForEach(month) { ChoreRow(due: $0) } } header: { Text("Tento mesiac") } footer: { Text("Do \(Fmt.date(today.monthEnd))") }
            }
            if !plans.isEmpty {
                Section("V kalendári") { ForEach(plans) { EventRow(event: $0) } }
            }
            if !toBuy.isEmpty {
                Section("Kúpiť") {
                    ForEach(toBuy.prefix(5)) { ShopRow(item: $0) }
                    if toBuy.count > 5 { Text("a ďalšie \(toBuy.count - 5)").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section { SyncStatus() }
        }
        .navigationTitle(Fmt.weekday(today))
        .refreshable { await store.sync(); calendar.reload() }
    }
}

struct EventRow: View {
    let event: MobileCalendar.Event
    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(event.color).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1)
                Text(event.allDay ? "Celý deň · \(event.calendar)"
                     : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: Úlohy

struct TasksTab: View {
    @Environment(Store.self) private var store
    @State private var editing: HomeTask?

    var body: some View {
        let sorted = store.tasks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let groups: [(String, [HomeTask])] = [
            ("Každý deň a v určité dni", sorted.filter { if case .daily = $0.repeatRule { return true }; if case .weekly = $0.repeatRule { return true }; return false }),
            ("Raz za týždeň alebo pár týždňov", sorted.filter { $0.isFlexible && $0.period == .week }),
            ("Raz za mesiac a menej často", sorted.filter { $0.isFlexible && $0.period == .month }),
            ("Jednorazové", sorted.filter { if case .once = $0.repeatRule { return true }; return false }),
        ]
        List {
            let f = store.fairness()
            if f.count > 1 {
                Section("Kto čo spravil za 30 dní") {
                    ForEach(f, id: \.name) { m in
                        HStack { WhoDot(who: m.name); Text(m.name); Spacer(); Text("\(m.count)").monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            }
            ForEach(groups, id: \.0) { title, items in
                if !items.isEmpty {
                    Section(title) {
                        ForEach(items) { t in
                            Button { editing = t } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: t.part.symbol).foregroundStyle(Color.leaf).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).foregroundStyle(.primary)
                                        Text("\(t.repeatTitle) · \(Who.title(t.who))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions { Button("Vymazať", role: .destructive) { store.delete(t) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Úlohy")
        .toolbar {
            Button { editing = HomeTask(title: "", repeatRule: .weekly([Day.today.weekday])) } label: { Image(systemName: "plus") }
        }
        .sheet(item: $editing) { t in TaskEditor(task: t, isNew: store.task(t.id) == nil) }
        .refreshable { await store.sync() }
    }
}

struct TaskEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var task: HomeTask
    let isNew: Bool

    enum Kind: String, CaseIterable {
        case once, daily, weekdays, weeks, months, window
        var title: String {
            switch self {
            case .once: "Raz, v určitý deň"
            case .daily: "Každý deň"
            case .weekdays: "V určité dni týždňa"
            case .weeks: "Raz za týždeň"
            case .months: "Raz za mesiac"
            case .window: "Raz, niekedy medzi"
            }
        }
    }
    @State private var kind = Kind.weekdays
    @State private var date = Date.now
    @State private var end = Date.now.addingTimeInterval(7 * 86400)
    @State private var weekdays: Set<Int> = []
    @State private var every = 1

    init(task: HomeTask, isNew: Bool) {
        _task = State(initialValue: task)
        self.isNew = isNew
        switch task.repeatRule {
        case .once(let d): _kind = State(initialValue: .once); _date = State(initialValue: d.date)
        case .daily: _kind = State(initialValue: .daily)
        case .weekly(let days): _kind = State(initialValue: .weekdays); _weekdays = State(initialValue: days)
        case let .flexible(p, e, _, _): _kind = State(initialValue: p == .week ? .weeks : .months); _every = State(initialValue: e)
        case let .window(s, e): _kind = State(initialValue: .window); _date = State(initialValue: s.date); _end = State(initialValue: e.date)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Napr. Vyniesť smeti", text: $task.title)
                Picker("Kto", selection: $task.who) {
                    ForEach(store.members, id: \.self) { Text($0).tag($0) }
                    Text(Who.title(Who.anyone)).tag(Who.anyone)
                    Text(Who.title(Who.takeTurns)).tag(Who.takeTurns)
                }
                Picker("Kedy cez deň", selection: $task.part) {
                    ForEach(DayPart.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Section("Ako často") {
                    Picker("Ako často", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                    switch kind {
                    case .once: DatePicker("Deň", selection: $date, displayedComponents: .date)
                    case .daily: EmptyView()
                    case .weekdays:
                        HStack {
                            ForEach(1...7, id: \.self) { d in
                                let on = weekdays.contains(d)
                                Text(Fmt.weekdayShort[d - 1]).font(.callout.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(on ? Color.leaf : Color.secondary.opacity(0.12), in: .circle)
                                    .foregroundStyle(on ? .white : .primary)
                                    .onTapGesture { if on { weekdays.remove(d) } else { weekdays.insert(d) } }
                            }
                        }
                    case .weeks: Stepper(every == 1 ? "Každý týždeň" : "Každé \(every) týždne", value: $every, in: 1...8)
                    case .months: Stepper(every == 1 ? "Každý mesiac" : "Každé \(every) mesiace", value: $every, in: 1...12)
                    case .window:
                        DatePicker("Od", selection: $date, displayedComponents: .date)
                        DatePicker("Do", selection: $end, in: date..., displayedComponents: .date)
                    }
                }
                if !isNew { Section { Button("Vymazať úlohu", role: .destructive) { store.delete(task); dismiss() } } }
            }
            .navigationTitle(isNew ? "Nová úloha" : "Upraviť")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušiť") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Pridať" : "Uložiť") { store.save(built); dismiss() }
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || (kind == .weekdays && weekdays.isEmpty))
                }
            }
        }
    }

    var built: HomeTask {
        var t = task
        let today = Day.today
        func anchor(_ p: Period) -> Int? {
            if case let .flexible(old, _, _, a) = task.repeatRule, old == p { return a }
            return nil
        }
        // Monthly chores limited to some months keep those months (the Mac app edits them).
        let months: Set<Int> = { if case let .flexible(.month, _, m, _) = task.repeatRule { return m }; return [] }()
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

// MARK: Nákup

struct ShoppingTab: View {
    @Environment(Store.self) private var store
    @State private var newItem = ""
    @FocusState private var focused: Bool

    var body: some View {
        let toBuy = store.shopping.filter { !$0.done }
        let bought = store.shopping.filter(\.done)
        List {
            Section {
                HStack {
                    TextField("Pridať (viac oddeľ čiarkou)", text: $newItem).focused($focused).submitLabel(.done).onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section(toBuy.isEmpty ? "Nič netreba" : "Kúpiť (\(toBuy.count))") {
                ForEach(toBuy) { ShopRow(item: $0) }
            }
            if !bought.isEmpty {
                Section {
                    ForEach(bought) { ShopRow(item: $0) }
                } header: { Text("Kúpené") } footer: {
                    Button("Vymazať kúpené", role: .destructive) { withAnimation { store.clearBought() } }.font(.footnote)
                }
            }
        }
        // The field keeps the keyboard up after each item (for adding several in a row), so there must be a way out:
        // scrolling the list or "Hotovo" above the keyboard hides it and brings the tab bar back.
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hotovo") { focused = false }.fontWeight(.semibold)
            }
        }
        .navigationTitle("Nákup")
        .refreshable { await store.sync() }
    }

    func add() {
        withAnimation(.snappy) { _ = store.addShopping(newItem.split(separator: ",").map(String.init)) }
        newItem = ""
        focused = true
    }
}

struct ShopRow: View {
    @Environment(Store.self) private var store
    let item: ShopItem
    var body: some View {
        Button { withAnimation(.snappy) { store.setBought(item, !item.done) } } label: {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(item.done ? Color.leaf : Color.secondary.opacity(0.5))
                Text(item.name).strikethrough(item.done, color: .secondary).foregroundStyle(item.done ? .secondary : .primary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions { Button("Odstrániť", role: .destructive) { store.remove(item) } }
        .sensoryFeedback(.selection, trigger: item.done)
    }
}

// MARK: Byt (devices)

struct DevicesTab: View {
    @Environment(Devices.self) private var devices

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Devices.scenes) { s in
                            let active = devices.activeScene == s.id
                            Button { withAnimation(.snappy) { devices.run(scene: s.id) } } label: {
                                Label(s.name, systemImage: s.symbol)
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .foregroundStyle(active ? .white : .primary)
                                    .background(active ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            } header: { Text("Scény") } footer: { Text("Ukážka, kým nie je pripojený Home Assistant. Druhé ťuknutie scénu vráti.") }

            Section {
                Toggle(isOn: Binding(get: { devices.frontDoorLocked }, set: { devices.setFrontDoor(locked: $0) })) {
                    Label(devices.frontDoorLocked ? "Dvere zamknuté" : "Dvere odomknuté", systemImage: devices.frontDoorLocked ? "lock.fill" : "lock.open.fill")
                }
                Picker(selection: Binding(get: { devices.alarm }, set: { devices.setAlarm($0) })) {
                    ForEach(AlarmMode.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Label("Alarm", systemImage: "shield.lefthalf.filled") }
            }

            ForEach(devices.rooms) { room in
                let items = devices.devices(in: room)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { DeviceRow(device: $0) }
                    } header: {
                        HStack { Text(room.name); Spacer(); Text("\(room.temperature.formatted(.number.precision(.fractionLength(1)))) °C") }
                    }
                }
            }
        }
        .navigationTitle("Byt")
    }
}

struct DeviceRow: View {
    @Environment(Devices.self) private var devices
    let device: Device
    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: device.symbol)
                    .foregroundStyle(device.active ? .white : .secondary)
                    .frame(width: 32, height: 32)
                    .background(device.active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.fill.tertiary), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                    Text(device.state).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if device.kind == .ac && device.on {
                    Stepper("", value: Binding(get: { device.level }, set: { devices.setLevel(device, $0) }), in: 16...30).labelsHidden()
                }
                Toggle("", isOn: Binding(get: { device.active }, set: { _ in devices.toggle(device) })).labelsHidden()
            }
            if [.light, .lamp, .speaker].contains(device.kind) && device.on || device.kind == .blinds {
                Slider(value: Binding(get: { draft ?? Double(device.level) }, set: { draft = $0 }), in: 0...100) { editing in
                    if !editing, let d = draft { devices.setLevel(device, Int(d.rounded())); draft = nil }
                }
                .tint(tint)
            }
        }
        .padding(.vertical, 2)
    }

    var tint: Color {
        switch device.kind {
        case .light, .lamp: .yellow
        case .blinds: .teal
        case .tv: .indigo
        case .speaker: .pink
        case .ac: device.acMode == .heat ? .orange : .cyan
        case .vacuum: .green
        }
    }
}

// MARK: Domácnosť

struct HouseholdTab: View {
    @Environment(Store.self) private var store
    @State private var newPassword = ""
    @State private var message: String?

    var body: some View {
        List {
            if let h = store.household {
                Section("Členovia") {
                    ForEach(h.members, id: \.userId) { m in
                        HStack { WhoDot(who: m.name); Text(m.name); if m.name == store.me { Text("ty").foregroundStyle(.secondary) } }
                    }
                }
                Section {
                    HStack {
                        Text(h.inviteCode).font(.title2.monospaced().weight(.semibold))
                        Spacer()
                        ShareLink(item: "Pridaj sa k našej domácnosti v Home, kód: \(h.inviteCode)") { Image(systemName: "square.and.arrow.up") }
                    }
                } header: { Text("Kód pozvánky") } footer: { Text("Druhý člen sa prihlási a v Home zadá tento kód.") }
            }
            Section("Účet") {
                LabeledContent("Prihlásený", value: store.email ?? "–")
                if let t = store.lastSync { LabeledContent("Synchronizované", value: t.formatted(date: .omitted, time: .shortened)) }
                SecureField("Nové heslo (aspoň 6 znakov)", text: $newPassword)
                Button("Zmeniť heslo") {
                    let p = newPassword
                    Task {
                        do { try await store.setPassword(p); newPassword = ""; message = "Heslo je zmenené." } catch { message = error.localizedDescription }
                    }
                }
                .disabled(newPassword.count < 6)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section { SyncStatus(); Button("Odhlásiť sa", role: .destructive) { store.signOut() } }
        }
        .navigationTitle(store.household?.name ?? "Domácnosť")
    }
}
#endif
