import SwiftUI

/// What the sidebar can show.
enum Folder: Hashable {
    case due, fading, celebrations, promises, followed, all
    case business(Business)

    init?(_ s: String) {
        switch s {
        case "due": self = .due
        case "fading": self = .fading
        case "celebrations": self = .celebrations
        case "promises": self = .promises
        case "followed": self = .followed
        case "all": self = .all
        default: return nil
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var folder: Folder? = .due
    /// A person's id, or "c|<celebration id>" for a celebration without a matching person.
    @State private var pick: String?
    @State private var query = ""
    @State private var mergeFrom: Person?
    @State private var assigning: Celebration?
    @AppStorage("sort") private var sortRaw = SortOrder.recent.rawValue
    @AppStorage("celebrationDays") private var celebrationDays = 30
    var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .recent }

    var body: some View {
        NavigationSplitView {
            Sidebar(data: store.data, selection: $folder)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            list
                .environment(\.mergePerson, { mergeFrom = $0 })
                .environment(\.hidePerson, hide)
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 480)
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 560)
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať človeka, firmu, e-mail")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.refresh() } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Label("Obnoviť", systemImage: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .help(store.loading ? "Načítavam z Brainu…" : "Obnoviť (⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Triediť podľa", selection: $sortRaw) {
                        ForEach(SortOrder.allCases) { o in Label(o.title, systemImage: o.symbol).tag(o.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Triedenie", systemImage: "arrow.up.arrow.down") }
                .help("Triediť: \(sort.title)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("Zdroje", systemImage: "slider.horizontal.3") }
                    .help("Ktoré zdroje Ľudia čítajú (⌘,)")
            }
        }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            applyPending()
            selectDefault()
        }
        .onChange(of: folder) { _, _ in pick = nil; selectDefault() }
        .onChange(of: query) { _, q in
            if !q.isEmpty, folder != .all { folder = .all }
            store.searchTopic(q)
        }
        .onChange(of: store.pendingSelection) { _, _ in applyPending() }
        .onChange(of: store.data?.generatedAt) { _, _ in
            if let id = store.pendingPerson, store.data?.person(id) != nil { store.pendingPerson = nil; folder = .all; pick = id }
        }
        .sheet(item: $mergeFrom) { p in
            MergeSheet(p: p, people: store.data?.people ?? []) { other, name in store.merge(p, with: other, keepName: name) }
        }
        .sheet(item: $assigning) { c in
            PersonPicker(title: "Čie sú narodeniny „\(c.who)“?", note: "Brain si to zapamätá a ďalšie roky ich priradí sám.",
                         people: store.data?.people ?? [], suggest: c.who) { p in store.assignBirthday(c.who, to: p) }
        }
        .onChange(of: store.data?.generatedAt) { _, _ in if pick == nil { selectDefault() } }
    }

    /// People of the selected folder (search looks through everyone).
    func people(_ d: Overview) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return d.people.filter { p in
                p.name.localizedCaseInsensitiveContains(q) || (p.company ?? "").localizedCaseInsensitiveContains(q)
                    || p.aliases.contains { $0.localizedCaseInsensitiveContains(q) } || p.emails.contains { $0.localizedCaseInsensitiveContains(q) }
                    || p.phones.contains { $0.contains(q.filter(\.isNumber)) && q.filter(\.isNumber).count >= 4 } || p.note.localizedCaseInsensitiveContains(q)
            }
        }
        switch folder ?? .due {
        case .due: return sort == .recent ? d.due.compactMap(d.person) : sort.sorted(d.due.compactMap(d.person))   // Brain's order: longest silence first
        case .fading: return sort == .recent ? d.fading.compactMap(d.person) : sort.sorted(d.fading.compactMap(d.person))   // strongest first
        case .promises: return sort.sorted(d.people.filter { $0.promisesOpen > 0 })
        case .followed: return sort.sorted(d.people.filter(\.follow))
        case .all, .celebrations: return sort.sorted(d.people)
        case .business(let b): return sort.sorted(d.people.filter { $0.biz == b })
        }
    }

    @ViewBuilder var list: some View {
        if let d = store.data {
            let f = query.isEmpty ? (folder ?? .due) : .all
            switch f {
            case .celebrations: CelebrationList(data: d, selection: $pick, days: $celebrationDays)
            case .due:
                PeopleList(people: people(d), selection: $pick, title: "Ozvi sa", grouped: false,
                           empty: ("Nikto nečaká", "checkmark.circle", "Ľuďom, ktorých sleduješ, si sa ozval včas. Sledovať niekoho: hviezdička v jeho detaile."))
            case .fading:
                PeopleList(people: people(d), selection: $pick, title: "Zabúdaš", grouped: false,
                           empty: ("Nikoho nezanedbávaš", "hourglass", "Ľudia, s ktorými si si veľa písal a teraz je ticho dlhšie ako \(d.settings.fadingDays) dní."))
            case .promises:
                PeopleList(people: people(d), selection: $pick, title: "Sľuby", grouped: false,
                           empty: ("Žiadne otvorené sľuby", "hand.raised", "Sľub pridáš v detaile človeka alebo cez Brain („sľúbil som Jane ponuku“)."))
            case .followed:
                PeopleList(people: people(d), selection: $pick, title: "Sledovaní", grouped: false,
                           empty: ("Nikoho nesleduješ", "star", "V detaile človeka klikni na hviezdičku a vyber, ako často sa chceš ozvať."))
            case .all where !query.isEmpty:
                SearchList(query: query, names: people(d), topic: store.topic, loading: store.topicLoading, data: d, selection: $pick)
            case .all:
                PeopleList(people: people(d), selection: $pick, title: "Všetci", grouped: sort == .recent, empty: ("Nikto", "person.2", ""))
            case .business(let b):
                PeopleList(people: people(d), selection: $pick, title: b.name, grouped: sort == .recent, empty: ("Nikto", b.symbol, ""))
            }
        } else if store.error != nil {
            Color.clear
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder var detail: some View {
        if let d = store.data {
            VStack(spacing: 0) {
                if let e = store.actionError {
                    Notice(symbol: "exclamationmark.triangle.fill", text: e, tint: .red).padding([.horizontal, .top], 16)
                        .onTapGesture { store.actionError = nil }
                }
                if let e = store.error { Notice(symbol: "exclamationmark.triangle.fill", text: "Obnovenie zlyhalo, sú tu staršie dáta. \(e)").padding([.horizontal, .top], 16) }
                ForEach(d.sources.filter { !$0.value.ok }.map(\.key).sorted(), id: \.self) { k in
                    Notice(symbol: "bolt.horizontal.circle.fill", text: "\(Source(rawValue: k)?.name ?? k.capitalized) neodpovedá: \(d.sources[k]?.error ?? "")", tint: .red)
                        .padding([.horizontal, .top], 16)
                }
                if let id = pick, id.hasPrefix("c|"), let c = d.celebrations.first(where: { "c|" + $0.id == id }) {
                    CelebrationDetail(c: c, onAssign: { assigning = c })
                } else if let id = pick, let p = d.person(id) {
                    PersonDetail(p: p, store: store, onHide: { hide(p) }, onMerge: { mergeFrom = p },
                                 topic: query.isEmpty ? nil : store.topic?.people.first { $0.id == id }.map { (query, $0) }).id(p.id)
                } else {
                    ContentUnavailableView("Vyber človeka", systemImage: "person.crop.circle", description: Text("Vľavo vyber človeka."))
                }
            }
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Ľudí sa nepodarilo načítať", systemImage: "exclamationmark.triangle")
            } description: { Text(e) } actions: { Button("Skúsiť znova") { store.refresh() } }
        } else {
            ContentUnavailableView {
                Label("Načítavam", systemImage: "person.2")
            } description: { Text("WhatsApp, Courier, Beeper, meetingy a kontakty cez Brain…") } actions: { ProgressView().controlSize(.small) }
        }
    }

    func hide(_ p: Person) {
        let shown = store.data.map(people) ?? []
        let next = shown.firstIndex(of: p).flatMap { i in shown.indices.contains(i + 1) ? shown[i + 1] : i > 0 ? shown[i - 1] : nil }
        store.set(p, .init(hidden: true))
        pick = next?.id
    }

    /// The first person of the list, so the detail isn't empty when a folder opens.
    func selectDefault() {
        guard pick == nil, let d = store.data else { return }
        if folder == .celebrations {
            pick = d.celebrations.first.map { $0.people.first ?? "c|" + $0.id }
        } else {
            pick = people(d).first?.id
        }
    }

    func applyPending() {
        guard let p = store.pendingSelection else { return }
        store.pendingSelection = nil
        query = ""
        folder = Folder(p) ?? .due
    }
}

struct Sidebar: View {
    let data: Overview?
    @Binding var selection: Folder?

    var body: some View {
        List(selection: $selection) {
            row("Ozvi sa", "bell.badge.fill", .orange, data?.due.count ?? 0, .due)
            row("Zabúdaš", "hourglass", .yellow, data?.fading.count ?? 0, .fading)
            row("Oslavy", "gift.fill", .pink, upcomingWeek, .celebrations)
            row("Sľuby", "hand.raised.fill", .red, data?.people.filter { $0.promisesOpen > 0 }.count ?? 0, .promises)
            row("Sledovaní", "star.fill", .yellow, data?.people.filter(\.follow).count ?? 0, .followed)
            row("Všetci", "person.2.fill", .blue, data?.people.count ?? 0, .all)
            Section("Skupiny") {
                ForEach(Business.allCases.filter { b in (data?.people.contains { $0.biz == b }) == true }) { b in
                    row(b.name, b.symbol, b.color, data?.people.filter { $0.biz == b }.count ?? 0, .business(b))
                }
            }
        }
        .listStyle(.sidebar)
    }

    func row(_ title: String, _ symbol: String, _ tint: Color, _ badge: Int, _ tag: Folder) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .badge(badge)
            .tag(tag)
    }

    var upcomingWeek: Int {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
        return data?.celebrations.filter { $0.day <= end }.count ?? 0
    }
}
