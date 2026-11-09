import AppKit
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case talked, connected, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .talked: "Posledná správa"
        case .connected: "Najnovšie kontakty"
        case .name: "Meno"
        }
    }
    var symbol: String {
        switch self {
        case .talked: "bubble.left.and.bubble.right"
        case .connected: "person.badge.plus"
        case .name: "textformat"
        }
    }
}

/// Role / seniority / country filters on people lists (from headlines and the country sync).
struct Filters: Equatable {
    var role: String?
    var seniority: String?
    var country: String?
    var isEmpty: Bool { role == nil && seniority == nil && country == nil }

    static let roles = ["Customer Service / CX", "Sales / BD", "Marketing", "IT / Engineering", "HR / Recruiting", "Finance",
                        "Operations / Logistics", "Product / Project", "Leadership", "Other"]
    static let seniorities = ["Owner / Founder", "C-level", "Director / Head", "Manager / Lead", "Specialist / Other", "Student"]

    func passes(_ c: Connection) -> Bool {
        (role == nil || c.role == role) && (seniority == nil || c.seniority == seniority)
            && (country == nil || (c.country ?? "Neznáma") == country)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var folder: Folder? = .reply
    @State private var picks: Set<String> = []
    @State private var query = ""
    @State private var filters = Filters()
    @State private var finding = false
    @State private var editingProject: Project?
    @State private var newProject = false
    @AppStorage("sort") private var sortRaw = SortOrder.talked.rawValue
    @AppStorage("pendingAge") private var pendingAge = 0
    var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .talked }

    var body: some View {
        NavigationSplitView {
            Sidebar(state: store.state, beeperOK: store.beeperError == nil && store.state?.beeperSyncedAt != nil, selection: $folder, onNewProject: { newProject = true }, onEditProject: { editingProject = $0 })
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } content: {
            list.navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            detail
        }
        .frame(minWidth: 1000, minHeight: 600)
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať meno, pozíciu, poznámku")
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { toastView }
        .sheet(isPresented: $finding) { FindSheet(store: store, folder: $folder) }
        .sheet(isPresented: $newProject) { ProjectSheet(store: store, project: nil) }
        .sheet(item: $editingProject) { p in ProjectSheet(store: store, project: p) }
        .onAppear {
            store.openMain = { [openWindow] in openWindow(id: "main") }
            applyPending()
            // The sidebar list picks its first row (a project) while it lays out; open on "Čaká na teba" instead.
            DispatchQueue.main.async { if store.pendingSelection == nil, case .project = folder { folder = .reply } }
        }
        .onChange(of: folder) { _, _ in picks = []; selectFirst() }
        .onChange(of: store.pendingSelection) { _, _ in applyPending() }
        .onChange(of: store.state?.connections.count) { _, _ in if picks.isEmpty { selectFirst() } }
    }

    // MARK: toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let b = store.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(b).font(.callout).foregroundStyle(.secondary) }
                    .padding(.horizontal, 6)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Nové kontakty") { store.sync(.connections(full: false)) }
                Button("Všetky kontakty (pár minút)") { store.sync(.connections(full: true)) }
                Button("Čakajúce pozvánky") { store.sync(.invites) }
                Divider()
                Menu("Krajina kontaktov") {
                    ForEach(store.state?.countries ?? [], id: \.self) { c in Button(c) { store.sync(.country(c)) } }
                }
            } label: { Label("Stiahnuť z LinkedInu", systemImage: "arrow.down.circle") }
            .disabled(store.busy != nil || store.state?.extensionConnected != true)
            .help(store.state?.extensionConnected == true ? "Stiahnuť z LinkedInu cez rozšírenie v Chrome" : "Rozšírenie v Chrome nie je pripojené")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { finding = true } label: { Label("Hľadať ľudí", systemImage: "person.crop.circle.badge.plus") }
                .help("Nájsť nových ľudí na LinkedIne (2. a 3. stupeň)")
                .disabled(store.state?.extensionConnected != true)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Triediť podľa", selection: $sortRaw) {
                    ForEach(SortOrder.allCases) { o in Label(o.title, systemImage: o.symbol).tag(o.rawValue) }
                }
                .pickerStyle(.inline)
                Section("Filtre") {
                    filterMenu("Rola", Filters.roles, $filters.role)
                    filterMenu("Seniorita", Filters.seniorities, $filters.seniority)
                    filterMenu("Krajina", (store.state?.countriesSyncedNames ?? []) + ["Neznáma"], $filters.country)
                    if !filters.isEmpty { Button("Zrušiť filtre") { filters = Filters() } }
                }
                if folder == .pending {
                    Picker("Staršie ako", selection: $pendingAge) {
                        Text("Všetky").tag(0); Text("2 týždne").tag(14); Text("Mesiac").tag(30); Text("3 mesiace").tag(90)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Triedenie a filtre", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Triediť: \(sort.title)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .help("Uložiť zobrazený zoznam ako CSV")
                .disabled(!(folder?.isPeople ?? false))
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.refresh() } label: { Label("Obnoviť", systemImage: "arrow.clockwise") }
                .disabled(store.loading)
                .help("Obnoviť (⌘R)")
        }
    }

    func filterMenu(_ title: String, _ options: [String], _ value: Binding<String?>) -> some View {
        Picker(title, selection: value) {
            Text("Všetky").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }

    // MARK: lists

    func people(_ s: AppState) -> [Connection] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(separator: " ").map(String.init)
        var list: [Connection]
        switch folder ?? .all {
        case .project(let id): list = s.connections.filter { $0.projects[id] != nil }
        case .talked: list = s.connections.filter { $0.lastMessageAt != nil }
        case .never: list = s.connections.filter { $0.lastMessageAt == nil }
        case .doNotContact: list = s.connections.filter(\.doNotContact)
        default: list = s.connections
        }
        list = list.filter { c in
            guard filters.passes(c) else { return false }
            if words.isEmpty { return true }
            let hay = "\(c.name) \(c.headline) \(c.note) \(c.location ?? "")".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return words.allSatisfy(hay.contains)
        }
        switch sort {
        case .talked: list.sort { ($0.lastMessageAt ?? 0, $0.connectedAt ?? 0) > ($1.lastMessageAt ?? 0, $1.connectedAt ?? 0) }
        case .connected: list.sort { ($0.connectedAt ?? 0) > ($1.connectedAt ?? 0) }
        case .name: list.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        return list
    }

    func matches(_ text: String) -> Bool {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(separator: " ").map(String.init)
        let hay = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return words.allSatisfy(hay.contains)
    }

    func conversations(_ s: AppState) -> [Conversation] {
        s.conversations.filter { c in
            let inFolder = switch folder {
            case .reply: s.needsReply(c)
            case .waiting: c.waiting
            default: c.group != true
            }
            return inFolder && matches("\(c.with) \(c.headline ?? "") \(c.lastText ?? "")")
        }
    }

    func prospects(_ s: AppState) -> [Prospect] {
        let invited = folder == .invited
        var list = s.prospects.filter { ($0.invitedAt != nil) == invited && matches("\($0.name) \($0.headline ?? "") \($0.location ?? "")") }
        if !invited, !store.found.isEmpty {
            // the last search first, in LinkedIn's order
            let order = Dictionary(store.found.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            list.sort { (order[$0.slug] ?? Int.max, $1.foundAt ?? "") < (order[$1.slug] ?? Int.max, $0.foundAt ?? "") }
        } else {
            list.sort { ($0.invitedAt ?? $0.foundAt ?? "") > ($1.invitedAt ?? $1.foundAt ?? "") }
        }
        return list
    }

    func invites(_ s: AppState) -> [SentInvite] {
        s.sentInvites.filter { $0.daysAgo >= pendingAge && matches("\($0.name) \($0.headline ?? "")") }
    }

    @ViewBuilder var list: some View {
        if let s = store.state {
            switch folder ?? .all {
            case .project(let id):
                ProjectList(state: s, project: s.project(id), people: people(s), selection: $picks)
            case .all, .talked, .never, .doNotContact:
                PeopleList(state: s, people: people(s), selection: $picks, title: title, empty: emptyText)
            case .reply, .waiting, .conversations:
                ConversationList(state: s, conversations: conversations(s), selection: $picks, title: title, empty: emptyText)
            case .prospects, .invited:
                ProspectList(state: s, prospects: prospects(s), selection: $picks, title: title, empty: emptyText, onFind: { finding = true })
            case .pending:
                InviteList(invites: invites(s), selection: $picks, title: title, syncedAt: s.sentInvitesSyncedAt)
            }
        } else if store.error != nil {
            Color.clear
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var title: String {
        switch folder ?? .all {
        case .project(let id): store.state?.project(id)?.name ?? id
        case .all: "Všetky kontakty"
        case .talked: "Písali sme si"
        case .never: "Nikdy sme si nepísali"
        case .doNotContact: "Nekontaktovať"
        case .reply: "Čaká na teba"
        case .waiting: "Čakáš na nich"
        case .conversations: "Všetky konverzácie"
        case .prospects: "Prospekti"
        case .invited: "Pozvaní cez Herald"
        case .pending: "Čakajúce pozvánky"
        }
    }

    var emptyText: (String, String, String) {
        if !query.isEmpty || !filters.isEmpty { return ("Nič sa nenašlo", "magnifyingglass", "Skús iné slová alebo zruš filtre.") }
        switch folder ?? .all {
        case .reply: return ("Nikto nečaká", "checkmark.circle", "Na všetky správy z posledného mesiaca si odpísal.")
        case .waiting: return ("Nikomu nepíšeš do prázdna", "clock", "Konverzácie, kde si písal posledný pred 3 až 60 dňami.")
        case .prospects: return ("Žiadni prospekti", "person.crop.circle.badge.plus", "Nájdi nových ľudí tlačidlom Hľadať ľudí.")
        case .invited: return ("Zatiaľ nikto", "paperplane", "Pozvánky poslané z Heraldu sa ukážu tu.")
        case .doNotContact: return ("Nikto", "hand.raised", "Ľudia so značkou do-not-contact.")
        default: return ("Nikto", "person.2", "Stiahni kontakty z LinkedInu.")
        }
    }

    // MARK: detail

    @ViewBuilder var detail: some View {
        if let s = store.state {
            VStack(spacing: 0) {
                if let e = store.actionError {
                    Notice(symbol: "exclamationmark.triangle.fill", text: e, tint: .red).padding([.horizontal, .top], 16)
                        .onTapGesture { store.actionError = nil }
                }
                if let e = store.error { Notice(symbol: "exclamationmark.triangle.fill", text: "Obnovenie zlyhalo, sú tu staršie dáta. \(e)").padding([.horizontal, .top], 16) }
                if let e = store.beeperError {
                    Notice(symbol: "bubble.left.and.exclamationmark.bubble.right.fill", text: "Správy z Beepera sa nedajú načítať, ukazujem staršie. \(e)", tint: .orange)
                        .padding([.horizontal, .top], 16)
                }
                if s.extensionConnected != true {
                    Notice(symbol: "bolt.horizontal.circle.fill",
                           text: "Rozšírenie v Chrome nie je pripojené. Správy idú cez Beeper, ale sťahovanie kontaktov, hľadanie ľudí a pozvánky čakajú na Chrome s prihláseným LinkedInom.",
                           tint: .orange).padding([.horizontal, .top], 16)
                }
                selectionDetail(s)
            }
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Herald sa nevie spojiť so serverom", systemImage: "exclamationmark.triangle")
            } description: { Text(e) } actions: { Button("Skúsiť znova") { store.refresh() } }
        } else {
            ContentUnavailableView { Label("Načítavam", systemImage: "person.2") } description: { Text("Kontakty, správy a projekty…") }
        }
    }

    @ViewBuilder func selectionDetail(_ s: AppState) -> some View {
        if picks.count > 1 {
            BulkDetail(state: s, store: store, ids: Array(picks), folder: folder ?? .all)
        } else if let id = picks.first {
            switch folder ?? .all {
            case .reply, .waiting, .conversations:
                if let c = s.conversations.first(where: { $0.id == id }) {
                    if let pid = c.connectionId, let p = s.byId[pid] { PersonDetail(c: p, state: s, store: store).id(p.id) }
                    else { ConversationDetail(c: c) }
                }
            case .prospects, .invited:
                if let p = s.prospects.first(where: { $0.slug == id }) { ProspectDetail(p: p, state: s, store: store).id(p.slug) }
            case .pending:
                if let i = s.sentInvites.first(where: { $0.id == id }) { InviteDetail(i: i, store: store) }
            default:
                if let p = s.byId[id] { PersonDetail(c: p, state: s, store: store).id(p.id) }
            }
        } else if case .project(let id) = folder, let p = s.project(id) {
            ProjectOverview(project: p, state: s, onEdit: { editingProject = p })
        } else {
            ContentUnavailableView("Vyber človeka", systemImage: "person.crop.circle", description: Text("Vľavo vyber jedného alebo viac ľudí (⌘-klik)."))
        }
    }

    // MARK: misc

    @ViewBuilder var toastView: some View {
        if let t = store.toast {
            Label(t, systemImage: "checkmark.circle.fill")
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 18)
                .task(id: t) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.toast == t { store.toast = nil }
                }
                .onTapGesture { store.toast = nil }
        }
    }

    func selectFirst() {
        guard picks.isEmpty, let s = store.state, let f = folder else { return }
        if case .project = f { return }   // the project's overview shows until someone is picked
        let first: String? = switch f {
        case .reply, .waiting, .conversations: conversations(s).first?.id
        case .prospects, .invited: prospects(s).first?.slug
        case .pending: invites(s).first?.id
        default: people(s).first?.id
        }
        if let first { picks = [first] }
    }

    func applyPending() {
        guard let p = store.pendingSelection else { return }
        store.pendingSelection = nil
        query = ""
        folder = Folder(p) ?? .reply
    }

    func exportCSV() {
        guard let s = store.state else { return }
        let rows = picks.count > 1 ? people(s).filter { picks.contains($0.id) } : people(s)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? CSV.people(rows, projects: s.projects).write(to: url, atomically: true, encoding: .utf8)
        store.toast = "Uložených \(Fmt.people(rows.count))."
    }
}

enum CSV {
    static func people(_ list: [Connection], projects: [Project]) -> String {
        func q(_ s: String?) -> String { "\"\((s ?? "").replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let head = ["Meno", "Priezvisko", "Pozícia", "Rola", "Seniorita", "Krajina", "Lokalita", "LinkedIn", "Spojení od", "Posledná správa"]
            + projects.map(\.name) + ["Značky", "Poznámka"]
        let lines = list.map { c in
            ([c.firstName, c.lastName, c.headline, c.role, c.seniority, c.country, c.location, c.url?.absoluteString,
              c.connected.map { $0.formatted(.iso8601.year().month().day()) }, c.lastTalk.map { $0.formatted(.iso8601.year().month().day()) }]
                + projects.map { c.projects[$0.id]?.stage } + [c.tags.joined(separator: ", "), c.note]).map(q).joined(separator: ",")
        }
        return ([head.map(q).joined(separator: ",")] + lines).joined(separator: "\n")
    }
}

extension AppState {
    var countriesSyncedNames: [String] { Array(Set(connections.compactMap(\.country))).sorted() }
}

// MARK: sidebar

struct Sidebar: View {
    let state: AppState?
    var beeperOK = true
    @Binding var selection: Folder?
    let onNewProject: () -> Void
    let onEditProject: (Project) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Projekty") {
                ForEach((state?.projects ?? []).filter { $0.archived != true }) { p in
                    Label { Text(p.name) } icon: { Image(systemName: "flag.fill").foregroundStyle(p.tint) }
                        .badge(p.people)
                        .tag(Folder.project(p.id))
                        .contextMenu { Button("Upraviť projekt…") { onEditProject(p) } }
                }
                Button(action: onNewProject) {
                    Label("Nový projekt", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Správy") {
                row("Čaká na teba", "arrowshape.turn.up.left.fill", .orange, state.map { s in s.conversations.filter(s.needsReply).count } ?? 0, .reply)
                row("Čakáš na nich", "clock.fill", .yellow, state?.conversations.filter(\.waiting).count ?? 0, .waiting)
                row("Všetky konverzácie", "bubble.left.and.bubble.right.fill", .blue, state?.conversations.filter { $0.group != true }.count ?? 0, .conversations)
            }
            Section("Kontakty") {
                row("Všetky kontakty", "person.2.fill", .blue, state?.connections.count ?? 0, .all)
                row("Písali sme si", "bubble.left.fill", .teal, state?.connections.filter { $0.lastMessageAt != nil }.count ?? 0, .talked)
                row("Nikdy sme si nepísali", "circle.dashed", .gray, state?.connections.filter { $0.lastMessageAt == nil }.count ?? 0, .never)
                row("Nekontaktovať", "hand.raised.fill", .red, state?.connections.filter(\.doNotContact).count ?? 0, .doNotContact)
            }
            Section("Rast siete") {
                row("Prospekti", "person.crop.circle.badge.plus", .green, state?.prospects.filter { $0.invitedAt == nil }.count ?? 0, .prospects)
                row("Pozvaní cez Herald", "paperplane.fill", .indigo, state?.prospects.filter { $0.invitedAt != nil }.count ?? 0, .invited)
                row("Čakajúce pozvánky", "hourglass", .purple, state?.sentInvites.count ?? 0, .pending)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { status }
    }

    func row(_ title: String, _ symbol: String, _ tint: Color, _ badge: Int, _ tag: Folder) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .badge(badge)
            .tag(tag)
    }

    var status: some View {
        let on = state?.extensionConnected == true
        let beeper = beeperOK
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(beeper ? .green : .orange).frame(width: 7, height: 7)
                Text(beeper ? "Správy z Beepera" : "Beeper neodpovedá").font(.caption).foregroundStyle(.secondary)
            }
            .help(beeper ? "LinkedIn správy sa čítajú z Beeper Desktop cez Brain." : "Otvor Beeper Desktop (a v Brainе beeper-login).")
            HStack(spacing: 6) {
                Circle().fill(on ? .green : .orange).frame(width: 7, height: 7)
                Text(on ? "Chrome pripojený" : "Chrome nepripojený").font(.caption).foregroundStyle(.secondary)
            }
            .help(on ? "Rozšírenie v Chrome je pripojené: kontakty, hľadanie ľudí a pozvánky." : "Kontakty, hľadanie ľudí a pozvánky potrebujú Chrome s rozšírením a prihláseným LinkedInom.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
