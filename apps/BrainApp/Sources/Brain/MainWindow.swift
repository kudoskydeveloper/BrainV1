import AppKit
import BrainCore
import ServiceManagement
import SwiftUI

/// The Brain window, in the style of the Hangar apps (Fitness, …): a sidebar with everything around the panel
/// (conversations, what Brain knows, timers, commands, settings). The ⌥Space panel stays the place to ask.
enum BrainSection: String, CaseIterable, Identifiable {
    case chats, map, knowledge, timers, commands, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chats: "Rozhovory"
        case .map: "Mapa"
        case .knowledge: "Čo Brain vie"
        case .timers: "Timery"
        case .commands: "Príkazy"
        case .settings: "Nastavenia"
        }
    }
    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.text.bubble.right.fill"
        case .map: "point.3.connected.trianglepath.dotted"
        case .knowledge: "books.vertical.fill"
        case .timers: "alarm.fill"
        case .commands: "command"
        case .settings: "gearshape.fill"
        }
    }
    var tint: Color {
        switch self {
        case .chats: .brainAccent
        case .map: .teal
        case .knowledge: .orange
        case .timers: .pink
        case .commands: .indigo
        case .settings: .gray
        }
    }
}

/// Which section the window shows; the panel and the menu bar item open the window at a section through it.
@MainActor
final class WindowNav: ObservableObject {
    @Published var section: BrainSection = .chats
    @Published var chat: UUID?
}

/// What the window can ask the app to do (the panel and the background jobs live in AppDelegate).
struct WindowActions {
    var continueChat: (Chat) -> Void
    var newChat: () -> Void
    var brief: () -> Void
    var rescan: () -> Void
    var login: (Bool) -> Void
}

struct MainView: View {
    @ObservedObject var nav: WindowNav
    @ObservedObject var history = HistoryStore.shared
    @ObservedObject var timers = TimerStore.shared
    @StateObject var notes = NotesStore()
    let actions: WindowActions
    @State var query = ""
    @AppStorage("look") var look: Look = .auto

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                SwiftUI.Section {
                    row(.chats, badge: history.chats.count)
                    row(.map)
                    row(.knowledge, badge: notes.items.count)
                    row(.timers, badge: timers.jobs.count)
                }
                SwiftUI.Section("Brain") {
                    row(.commands)
                    row(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detail
                .navigationTitle(nav.section.title)
        }
        .frame(minWidth: 820, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { actions.newChat() } label: { Label("Opýtať sa", systemImage: "square.and.pencil") }
                    .help("Nový rozhovor v paneli (⌥Space)")
            }
        }
        .onChange(of: nav.section) { _, _ in query = ""; history.reload(); notes.reload() }
        .onAppear { history.reload(); notes.reload(); NSApp.windows.forEach { $0.appearance = look.appearance } }
        .onChange(of: look) { _, l in NSApp.windows.forEach { $0.appearance = l.appearance } }
    }

    func row(_ s: BrainSection, badge: Int = 0) -> some View {
        Label { Text(s.title) } icon: { Image(systemName: s.symbol).foregroundStyle(s.tint) }
            .badge(badge)
            .tag(s)
    }

    @ViewBuilder var detail: some View {
        switch nav.section {
        case .chats: ChatsPage(store: history, nav: nav, filter: query, actions: actions)
            .searchable(text: $query, placement: .toolbar, prompt: "Hľadať v rozhovoroch")
        case .knowledge: BrainPage { KnowledgeView(store: notes, filter: query) }
            .searchable(text: $query, placement: .toolbar, prompt: "Hľadať v tom, čo Brain vie")
        case .map: MapPage()
        case .timers: TimersPage(store: timers)
        case .commands: CommandsPage()
        case .settings: SettingsPage(actions: actions)
        }
    }
}

// MARK: building blocks (as in Fitness)

struct BrainPage<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let page = VStack(alignment: .leading, spacing: 16) { content }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        if snapshot { page.frame(maxHeight: .infinity, alignment: .top) } else { ScrollView { page } }
    }
}

extension EnvironmentValues {
    /// Rendering to an image (`Brain --window-snapshot`): no scroll views, they render empty.
    @Entry var snapshot = false
}

struct BrainCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let symbol { Label(title, systemImage: symbol).font(.headline) } else { Text(title).font(.headline) }
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .brainCard()
    }
}

extension View {
    func brainCard() -> some View {
        background(.background.secondary, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: conversations: the list on the left, the chosen one on the right, continued in the panel

struct ChatsPage: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var nav: WindowNav
    let filter: String
    let actions: WindowActions
    @State var renaming: Chat?
    @State var newTitle = ""

    var shown: [Chat] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return store.chats }
        return store.chats.filter { c in c.title.lowercased().contains(f) || c.messages.contains { $0.text.lowercased().contains(f) } }
    }

    var body: some View {
        HSplitView {
            List(selection: $nav.chat) {
                ForEach(groups, id: \.0) { title, chats in
                    SwiftUI.Section(title) {
                        ForEach(chats) { c in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                                Text("\(c.updated.formatted(date: .omitted, time: .shortened)) · \(c.messages.filter(\.mine).count) otázok")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .tag(c.id)
                            .contextMenu { menu(c) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView(store.chats.isEmpty ? "Zatiaľ žiadne rozhovory" : "Nič nenájdené",
                                           systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text(store.chats.isEmpty ? "Každá otázka z panelu sa sem uloží." : "Skús iné slovo."))
                }
            }

            Group {
                if let c = store.chats.first(where: { $0.id == nav.chat }) { transcript(c) }
                else { ContentUnavailableView("Vyber rozhovor", systemImage: "text.bubble", description: Text("Otvoríš ho tu a pokračuješ v ňom v paneli.")) }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $renaming) { c in
            VStack(alignment: .leading, spacing: 12) {
                Text("Premenovať rozhovor").font(.headline)
                TextField("Názov", text: $newTitle).textFieldStyle(.roundedBorder).frame(width: 340)
                    .onSubmit { store.rename(c.id, to: newTitle); renaming = nil }
                HStack { Spacer(); Button("Zrušiť") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Uložiť") { store.rename(c.id, to: newTitle); renaming = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
        }
    }

    /// Today, yesterday, this week, then by month.
    var groups: [(String, [Chat])] {
        let cal = Calendar.current
        func key(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Dnes" }
            if cal.isDateInYesterday(d) { return "Včera" }
            if let w = cal.date(byAdding: .day, value: -7, to: Date()), d > w { return "Posledných 7 dní" }
            return d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "sk_SK"))).capitalized
        }
        var out: [(String, [Chat])] = []
        for c in shown {
            let k = key(c.updated)
            if out.last?.0 == k { out[out.count - 1].1.append(c) } else { out.append((k, [c])) }
        }
        return out
    }

    @ViewBuilder func menu(_ c: Chat) -> some View {
        Button("Pokračovať v paneli") { actions.continueChat(c) }
        Button("Premenovať…") { newTitle = c.title; renaming = c }
        Divider()
        Button("Zmazať", role: .destructive) { if nav.chat == c.id { nav.chat = nil }; store.delete(c.id) }
    }

    func transcript(_ c: Chat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Text("\(c.created.formatted(date: .long, time: .shortened)) · \(c.messages.filter(\.mine).count) otázok")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { newTitle = c.title; renaming = c } label: { Image(systemName: "pencil") }.help("Premenovať")
                Button(role: .destructive) { nav.chat = nil; store.delete(c.id) } label: { Image(systemName: "trash") }.help("Zmazať")
                Button { actions.continueChat(c) } label: { Label("Pokračovať v paneli", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent).tint(.brainAccent)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(c.messages.enumerated()), id: \.offset) { _, l in Turn(message: Message(mine: l.mine, text: l.text)) }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(c.id)
        }
    }
}

// MARK: timers

struct TimersPage: View {
    @ObservedObject var store: TimerStore

    var body: some View {
        if store.jobs.isEmpty {
            ContentUnavailableView {
                Label("Žiadne timery", systemImage: "alarm")
            } description: {
                Text("V paneli napíš napr. „o hodinu skontroluj moje pozície“ alebo `/timer pripomeň 8:00 zavolať Petrovi`.")
            }
        } else {
            BrainPage {
                ForEach(Array(store.jobs.enumerated()), id: \.element.id) { i, j in
                    TimerCard(n: i + 1, job: j, cancel: { store.cancel([j.id]) }, save: { store.update($0) })
                }
                Text("Zrušené timery sa nedajú vrátiť; nový nastavíš v paneli.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TimerCard: View {
    let n: Int
    let job: TimerStore.Job
    let cancel: () -> Void
    let save: (TimerStore.Job) -> Void
    @State var confirm = false
    @State var editing = false

    var mode: (String, String, Color) {
        job.remind == true ? ("Pripomenie", "bell.fill", .orange)
            : job.approved == true ? ("Urobí sám", "bolt.fill", .pink) : ("Spýta sa", "questionmark.bubble.fill", .brainAccent)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: mode.1).font(.title3).foregroundStyle(mode.2).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.at.formatted(.dateTime.weekday(.wide).day().month().hour().minute().locale(Locale(identifier: "sk_SK"))))
                        .font(.headline)
                    Text(mode.0).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(mode.2.opacity(0.14), in: Capsule()).foregroundStyle(mode.2)
                    if let e = job.every, let u = job.until {
                        Label("každých \(Session.human(e)) do \(u.formatted(date: .abbreviated, time: .shortened))", systemImage: "repeat")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(job.prompt).font(.callout).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                HStack(spacing: 10) {
                    if let a = job.app.flatMap({ BrainApps.find("/" + $0) }) {
                        Label(a.name, systemImage: a.symbol).font(.caption).foregroundStyle(a.color)
                    }
                    if let f = job.from { Text("z rozhovoru „\(f)“").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Spacer(minLength: 8)
            Button("Upraviť") { editing = true }.controlSize(.small)
                .sheet(isPresented: $editing) { TimerEditor(job: job, save: save) }
            Button("Zrušiť") { confirm = true }.controlSize(.small)
                .confirmationDialog("Zrušiť timer \(n)?", isPresented: $confirm) {
                    Button("Zrušiť timer", role: .destructive, action: cancel)
                } message: { Text(String(job.prompt.prefix(140))) }
        }
        .padding(16)
        .brainCard()
    }
}

// MARK: commands and shortcuts

struct CommandsPage: View {
    var body: some View {
        BrainPage {
            BrainCard("Príkazy v paneli", subtitle: "Napíš ich do poľa v paneli (⌥Space).", symbol: "terminal") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(Session.commands, id: \.0) { k, v in
                        GridRow {
                            Text(k).font(.callout.monospaced()).textSelection(.enabled)
                            Text(v).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            BrainCard("Skratky", symbol: "keyboard") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(Session.shortcuts, id: \.0) { k, v in
                        GridRow {
                            Text(k).font(.callout.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                            Text(v).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            BrainCard("Bežnou rečou", symbol: "text.bubble") {
                Text("Timery, pripomienky a opakovanie vieš zadať aj slovami, napr. „o hodinu skontroluj moje pozície“, „pripomeň mi v pondelok o 9:00 odpísať Petrovi“ alebo „pošli ten e-mail v pondelok o 8:00“ (Courier ho naplánuje).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: settings

struct SettingsPage: View {
    let actions: WindowActions
    @AppStorage("look") var look: Look = .auto
    /// "e-mail (plan)", nil while loading, .some(nil) when logged out.
    @State var account: String??
    @State var atLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("notchMode") var notchMode = false

    var body: some View {
        Form {
            SwiftUI.Section("Vzhľad") {
                Picker("Režim", selection: $look) { ForEach(Look.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
            }
            SwiftUI.Section {
                Toggle(isOn: $notchMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brain pod notchom")
                        Text("Pri notchi ukáže, čo práve robí, čaká na potvrdenie alebo čo príde o chvíľu; keď naň prejdeš myšou, otvorí sa malé menu. Odpovede a timery sa ukážu tam namiesto notifikácie.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!NotchController.available)
            } header: { Text("Notch") } footer: {
                if !NotchController.available { Text("Tento displej nemá notch.").font(.caption) }
            }
            SwiftUI.Section("Claude účet") {
                LabeledContent("Brain sa pýta ako") {
                    switch account {
                    case .none: ProgressView().controlSize(.small)
                    case .some(.none): Text("Neprihlásený").foregroundStyle(.orange)
                    case .some(.some(let a)): Text(a).textSelection(.enabled)
                    }
                }
                HStack {
                    Spacer()
                    Button(account == .some(nil) ? "Prihlásiť sa" : "Prihlásiť iný účet…") { actions.login(account == .some(nil)) }
                }
            }
            SwiftUI.Section("Spustenie") {
                Toggle("Spúšťať Brain po prihlásení", isOn: $atLogin)
                    .onChange(of: atLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        atLogin = SMAppService.mainApp.status == .enabled
                    }
                LabeledContent("Otvoriť panel", value: "⌥Space")
            }
            SwiftUI.Section("Údržba") {
                LabeledContent("Ranný prehľad") { Button("Zobraziť teraz", action: actions.brief) }
                LabeledContent("Index súborov a ľudí") { Button("Prehľadať znova", action: actions.rescan) }
                LabeledContent("Poznámky Brainu") { Button("Otvoriť priečinok") { NSWorkspace.shared.open(NotesStore.dir) } }
                LabeledContent("Log") {
                    Button("Otvoriť") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Brain.log")) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .onAppear { account = nil; Runner.account { a in account = .some(a) } }
    }
}

/// Edit a timer: what it should do, when, how (ask / do it / just remind), how often, with which app.
struct TimerEditor: View {
    @Environment(\.dismiss) var dismiss
    let save: (TimerStore.Job) -> Void
    @State var job: TimerStore.Job
    @State var mode: Int
    @State var repeats: Bool
    @State var everyMinutes: Int
    @State var until: Date

    init(job: TimerStore.Job, save: @escaping (TimerStore.Job) -> Void) {
        self.save = save
        _job = State(initialValue: job)
        _mode = State(initialValue: job.remind == true ? 2 : job.approved == true ? 1 : 0)
        _repeats = State(initialValue: job.every != nil)
        _everyMinutes = State(initialValue: Int((job.every ?? 900) / 60))
        _until = State(initialValue: job.until ?? job.at.addingTimeInterval(7200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                SwiftUI.Section(mode == 2 ? "Text pripomienky" : "Čo má Brain urobiť") {
                    TextEditor(text: Binding(get: { job.prompt }, set: { job = copy(prompt: $0) }))
                        .font(.body).frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                }
                SwiftUI.Section("Kedy") {
                    DatePicker("Čas", selection: Binding(get: { job.at }, set: { job = copy(at: $0) }), in: Date()...)
                    Toggle("Opakovať", isOn: $repeats)
                    if repeats {
                        Stepper("Každých \(everyMinutes) min", value: $everyMinutes, in: 1...1440, step: everyMinutes < 15 ? 1 : 15)
                        DatePicker("Do", selection: $until, in: job.at...job.at.addingTimeInterval(7 * 86400))
                    }
                }
                SwiftUI.Section("Ako") {
                    Picker("Režim", selection: $mode) {
                        Text("Spýta sa").tag(0)
                        Text("Urobí sám").tag(1)
                        Text("Len pripomenie").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text(["Brain to urobí a zmeny ti dá na potvrdenie.", "Brain to urobí bez pýtania (obchody nikdy).",
                          "Len notifikácia s textom, nič sa nespustí."][mode]).font(.caption).foregroundStyle(.secondary)
                    if mode != 2 {
                        Picker("Appka", selection: Binding(get: { job.app ?? "" }, set: { job = copy(app: $0.isEmpty ? nil : $0) })) {
                            Text("Brain vyberie sám").tag("")
                            Divider()
                            ForEach(BrainApps.all) { a in Label(a.name, systemImage: a.symbol).tag(a.slug) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Zrušiť") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uložiť") {
                    var j = job
                    j.approved = mode == 1; j.remind = mode == 2
                    j.every = repeats ? TimeInterval(everyMinutes * 60) : nil
                    j.until = repeats ? until : nil
                    save(j); dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.brainAccent)
                .disabled(job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    /// Job's prompt and time are constants: rebuild it with one of them changed.
    func copy(prompt: String? = nil, at: Date? = nil, app: String?? = nil) -> TimerStore.Job {
        var j = TimerStore.Job(id: job.id, prompt: prompt ?? job.prompt, at: at ?? job.at, from: job.from, approved: job.approved,
                               every: job.every, until: job.until, runs: job.runs, remind: job.remind)
        j.app = app ?? job.app
        return j
    }
}
