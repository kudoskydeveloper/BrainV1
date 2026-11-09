import SwiftUI

struct PersonHeader: View {
    let name: String
    let headline: String?
    let lines: [String]
    let url: URL?
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(name: name, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let headline, !headline.isEmpty { Text(headline).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach(lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let url {
                Button { open(url) } label: { Label("Profil", systemImage: "arrow.up.right.square") }
                    .help(url.absoluteString)
            }
        }
    }
}

/// Where someone stands in each project, with a stage picker; and adding them to another project.
struct ProjectsCard: View {
    let memberships: [String: Membership]
    let state: AppState
    let onSet: (String, String?) -> Void

    var body: some View {
        let others = state.projects.filter { $0.archived != true && memberships[$0.id] == nil }
        Card("Projekty", symbol: "flag.fill", tint: .accentColor) {
            if !others.isEmpty {
                Menu {
                    ForEach(others) { p in Button(p.name) { onSet(p.id, "lead") } }
                } label: { Label("Pridať", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        } content: {
            if memberships.isEmpty {
                Text("Zatiaľ v žiadnom projekte.").foregroundStyle(.secondary)
            }
            ForEach(memberships.sorted { $0.key < $1.key }, id: \.key) { id, m in
                HStack {
                    Image(systemName: "flag.fill").foregroundStyle(state.project(id)?.tint ?? .secondary)
                    Text(state.project(id)?.name ?? id).font(.body.weight(.medium))
                    Spacer()
                    if let at = Fmt.iso(m.at) { Text(Fmt.ago(Fmt.daysAgo(at))).font(.caption).foregroundStyle(.secondary) }
                    Picker("", selection: Binding(get: { m.stage }, set: { onSet(id, $0) })) {
                        ForEach(state.stages) { st in Label(st.label, systemImage: st.symbol).tag(st.key) }
                    }
                    .labelsHidden().fixedSize()
                    Menu {
                        Button("Odobrať z projektu", role: .destructive) { onSet(id, nil) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }
}

struct PersonDetail: View {
    let c: Connection
    let state: AppState
    @ObservedObject var store: Store
    @Environment(\.snapshot) private var snapshot
    @State private var note = ""
    @State private var newTag = ""

    var body: some View {
        Page {
            PersonHeader(name: c.name, headline: c.headline, lines: infoLines, url: c.url)
            if c.doNotContact {
                Notice(symbol: "hand.raised.fill", text: "Nekontaktovať. Herald ani Claude tomuto človeku nič nenavrhnú.", tint: .red)
            }
            ProjectsCard(memberships: c.projects, state: state) { project, stage in store.setStage(ids: [c.id], project: project, stage: stage) }
            if let conv = state.conversationByPerson[c.id] { LastMessageCard(c: conv, waiting: state.needsReply(conv), done: state.isDone(conv)) }
            if !snapshot {
                EmailCard(name: c.name, note: c.note) { e in store.tag([c.id], note: c.note.isEmpty ? e : "\(c.note)\n\(e)") }
            }
            Card("Poznámka", symbol: "note.text", tint: .yellow) {
                TextField("Čo o človeku vieš, čo ste riešili…", text: $note, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...8)
                    .onSubmit(saveNote)
                if note != c.note {
                    HStack { Spacer(); Button("Uložiť", action: saveNote).keyboardShortcut(.return, modifiers: .command) }
                }
            }
            Card("Značky", symbol: "tag.fill", tint: .teal) {
                Toggle("Nekontaktovať", isOn: Binding(get: { c.doNotContact }, set: { on in
                    store.tag([c.id], add: on ? ["do-not-contact"] : [], remove: on ? [] : ["do-not-contact"])
                }))
                .toggleStyle(.switch).controlSize(.small)
            } content: {
                let tags = c.plainTags(state.projects)
                if !tags.isEmpty {
                    FlowRow(tags) { t in
                        TagChip(tag: t).contextMenu { Button("Odobrať značku", role: .destructive) { store.tag([c.id], remove: [t]) } }
                    }
                }
                TextField("Pridať značku", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let t = newTag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
                        if !t.isEmpty { store.tag([c.id], add: [t]) }
                        newTag = ""
                    }
            }
        }
        .onAppear { note = c.note }
        .onChange(of: c.note) { _, n in note = n }
    }

    var infoLines: [String] {
        var out: [String] = []
        let place = [c.location, c.country].compactMap { $0 }.first
        let kind = [c.role, c.seniority].compactMap { $0 }.filter { $0 != "Other" }.joined(separator: " · ")
        if let place { out.append(place) }
        if !kind.isEmpty { out.append(kind) }
        if let d = c.connected { out.append("V kontaktoch od \(Fmt.date(d))") }
        return out
    }

    func saveNote() { if note != c.note { store.tag([c.id], note: note) } }
}

struct LastMessageCard: View {
    let c: Conversation
    var waiting = false
    var done = false
    var body: some View {
        Card("Posledná správa", symbol: "bubble.left.and.bubble.right.fill", tint: .blue) {
            if c.beeper == true {
                Button("Otvoriť Beeper") { openBeeper() }.buttonStyle(.link)
            } else if let u = c.url { Button("Otvoriť na LinkedIne") { open(u) }.buttonStyle(.link) }
        } content: {
            VStack(alignment: c.lastFrom == "me" ? .trailing : .leading, spacing: 4) {
                Text(c.lastText ?? "")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(c.lastFrom == "me" ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
                Text("\(c.lastFrom == "me" ? "Ty" : c.with), \(Fmt.ago(c.daysSinceLast))").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: c.lastFrom == "me" ? .trailing : .leading)
            if waiting {
                HStack {
                    Label("Čaká na tvoju odpoveď. Odpíš v Beeperi alebo cez Claude (Beeper).", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { Store.shared.markDone([c]) } label: { Label("Vybavené", systemImage: "checkmark.circle") }
                        .help("Netreba odpovedať. Vráti sa, keď napíšu znova.")
                }
            } else if done {
                HStack {
                    Label("Vybavené, kým nenapíšu znova.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Vrátiť") { Store.shared.markDone([c], undo: true) }.buttonStyle(.link)
                }
            }
        }
    }
}

struct ConversationDetail: View {
    let c: Conversation
    var body: some View {
        Page {
            PersonHeader(name: c.with, headline: c.headline, lines: [c.group == true ? "Skupinová konverzácia" : "Nie je v kontaktoch"], url: nil)
            LastMessageCard(c: c, waiting: c.theyWroteLast && !AppState.isAcknowledgement(c.lastText))
        }
    }
}

struct ProspectDetail: View {
    let p: Prospect
    let state: AppState
    @ObservedObject var store: Store
    @State private var inviting = false

    var body: some View {
        Page {
            PersonHeader(name: p.name, headline: p.headline, lines: [p.location, p.degree.map { "\($0) stupeň" }].compactMap { $0 }, url: p.url)
            if let m = p.mutual { Label(m, systemImage: "person.2").font(.callout).foregroundStyle(.secondary) }
            ProjectsCard(memberships: p.projects ?? [:], state: state) { project, stage in store.setStage(slugs: [p.slug], project: project, stage: stage) }
            Card("Pozvánka", symbol: "paperplane.fill", tint: .indigo) {
                if let at = Fmt.iso(p.invitedAt) {
                    Label("Pozvaný \(Fmt.date(at)). Čaká, kým prijme.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else if p.pending == true {
                    Label("Pozvánka už čaká (poslaná mimo Heraldu).", systemImage: "hourglass").foregroundStyle(.secondary)
                } else {
                    let b = state.inviteBudget
                    Text("Dnes \(b.today) z \(b.dailyCap), tento týždeň \(b.week) z \(b.weeklyCap).").font(.callout).foregroundStyle(.secondary)
                    if p.canConnect == false { Notice(symbol: "exclamationmark.triangle.fill", text: "LinkedIn tu neukázal tlačidlo Spojiť (možno len Sledovať).") }
                    Button { inviting = true } label: { Label("Poslať pozvánku…", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent)
                        .disabled(b.left == 0 || store.busy != nil || state.extensionConnected != true)
                }
            }
            if let q = p.query {
                Text("Nájdený cez hľadanie „\(q.keywords ?? "")“\(q.country.map { ", \($0)" } ?? "")\(Fmt.iso(p.foundAt).map { ", \(Fmt.date($0))" } ?? "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $inviting) { InviteSheet(p: p, state: state, store: store) }
    }
}

struct InviteDetail: View {
    let i: SentInvite
    @ObservedObject var store: Store
    @State private var confirm = false
    var body: some View {
        Page {
            PersonHeader(name: i.name, headline: i.headline, lines: ["Pozvánka poslaná \(i.sent), \(Fmt.ago(i.daysAgo))"], url: i.url)
            if let n = i.note { Card("Správa k pozvánke", symbol: "text.quote") { Text(n).textSelection(.enabled) } }
            Card("Stiahnuť pozvánku", symbol: "arrow.uturn.backward.circle", tint: .red) {
                Text("Staré nevybavené pozvánky znižujú tvoj limit. Toho istého človeka sa dá znova pozvať až asi o 3 týždne.").font(.callout).foregroundStyle(.secondary)
                Button("Stiahnuť…", role: .destructive) { confirm = true }.disabled(store.busy != nil)
            }
        }
        .confirmationDialog("Stiahnuť pozvánku pre \(i.name)?", isPresented: $confirm) {
            Button("Stiahnuť", role: .destructive) { store.withdraw([i.id]) }
        } message: { Text("Na LinkedIne sa zruší. Znova pozvať sa dá asi o 3 týždne.") }
    }
}

/// Several people picked (⌘-click, ⇧-click): move them all to a stage, tag them, or withdraw invites.
struct BulkDetail: View {
    let state: AppState
    @ObservedObject var store: Store
    let ids: [String]
    let folder: Folder
    @State private var tag = ""
    @State private var confirmWithdraw = false

    var connectionIds: [String] {
        switch folder {
        case .reply, .waiting, .conversations: ids.compactMap { id in state.conversations.first { $0.id == id }?.connectionId }
        case .prospects, .invited, .pending: []
        default: ids
        }
    }

    var body: some View {
        Page {
            Text("Vybraných \(ids.count)").font(.title2.weight(.semibold))
            if folder == .pending {
                Card("Stiahnuť pozvánky", symbol: "arrow.uturn.backward.circle", tint: .red) {
                    Text("Postupne, asi 6 s na jednu. Zastaví sa pri prvej chybe.").font(.callout).foregroundStyle(.secondary)
                    Button("Stiahnuť \(ids.count) pozvánok…", role: .destructive) { confirmWithdraw = true }.disabled(store.busy != nil || ids.count > 200)
                }
            } else {
                if [.reply, .waiting, .conversations].contains(folder) {
                    let convs = ids.compactMap { id in state.conversations.first { $0.id == id } }
                    Card("Vybavené", symbol: "checkmark.circle.fill", tint: .green) {
                        Text("Netreba odpovedať. Každá sa vráti do Čaká na teba, keď ten človek napíše znova.").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Označiť \(convs.count) ako vybavené") { Store.shared.markDone(convs) }
                            Button("Vrátiť") { Store.shared.markDone(convs, undo: true) }
                        }
                    }
                }
                Card("Presunúť do fázy", symbol: "flag.fill", tint: .accentColor) {
                    ForEach(state.projects.filter { $0.archived != true }) { p in
                        HStack {
                            Text(p.name).font(.body.weight(.medium))
                            Spacer()
                            Menu("Fáza") {
                                ForEach(state.stages) { st in Button { set(p.id, st.key) } label: { Label(st.label, systemImage: st.symbol) } }
                                Divider()
                                Button("Odobrať z projektu", role: .destructive) { set(p.id, nil) }
                            }
                            .fixedSize()
                        }
                    }
                }
                if !connectionIds.isEmpty {
                    Card("Značka", symbol: "tag.fill", tint: .teal) {
                        HStack {
                            TextField("napr. warm, event-2026", text: $tag).textFieldStyle(.roundedBorder)
                            Button("Pridať") { store.tag(connectionIds, add: [clean]); tag = "" }.disabled(clean.isEmpty)
                            Button("Odobrať") { store.tag(connectionIds, remove: [clean]); tag = "" }.disabled(clean.isEmpty)
                        }
                        Button("Označiť ako Nekontaktovať") { store.tag(connectionIds, add: ["do-not-contact"]) }
                    }
                }
            }
        }
        .confirmationDialog("Stiahnuť \(ids.count) pozvánok?", isPresented: $confirmWithdraw) {
            Button("Stiahnuť \(ids.count)", role: .destructive) { store.withdraw(ids) }
        } message: { Text("Na LinkedIne sa zrušia jedna po druhej. Znova pozvať sa dá asi o 3 týždne.") }
    }

    var clean: String { tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-") }

    func set(_ project: String, _ stage: String?) {
        let slugs = folder == .prospects || folder == .invited ? ids : []
        store.setStage(ids: connectionIds, slugs: slugs, project: project, stage: stage)
    }
}

/// A project with nobody picked: the pipeline at a glance.
struct ProjectOverview: View {
    let project: Project
    let state: AppState
    let onEdit: () -> Void
    var body: some View {
        Page {
            HStack {
                Label(project.name, systemImage: "flag.fill").font(.title2.weight(.semibold)).foregroundStyle(project.tint)
                Spacer()
                Button("Upraviť…", action: onEdit)
            }
            Text("Playbook „\(project.playbook)“ · \(Fmt.people(project.people)) · \(project.prospects) prospektov").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(state.stages) { st in StatTile(st.label, "\(project.stages[st.key] ?? 0)", symbol: st.symbol, tint: st.tint) }
            }
            let waiting = state.connections.filter { p in p.projects[project.id] != nil && state.conversationByPerson[p.id].map(state.needsReply) == true }
            if !waiting.isEmpty {
                Notice(symbol: "arrowshape.turn.up.left.fill", text: "\(Fmt.people(waiting.count)) z projektu \((2...4).contains(waiting.count) ? "čakajú" : "čaká") na tvoju odpoveď.")
            }
            Text("Claude číta playbook projektu pred každým oslovením (linkedin_playbook) a fázy mení sám, keď pošle správu alebo dostane odpoveď.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Chips that wrap onto more lines.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

// MARK: Scout: a LinkedIn contact's e-mail from their company's website

struct ScoutHit: Decodable, Hashable {
    var email: String?
    var confidence: String?
    var alternatives: [String]?
    var blocked: Bool?
    var why: String?
    var label: String { confidence == "found" ? "nájdená na webe" : confidence == "pattern" ? "podľa vzoru firmy" : confidence == "mx" ? "len odhad" : "" }
    var tint: Color { confidence == "found" ? .green : confidence == "pattern" ? .blue : .orange }
}

/// The company's domain in, the person's likely address out (`scout person`), with how sure it is. LinkedIn itself is never
/// asked for addresses; Scout reads only the company's public website.
struct EmailCard: View {
    let name: String
    let note: String
    let onSaveToNote: (String) -> Void
    @AppStorage("scoutDomains") private var remembered = "{}"
    @State private var domain = ""
    @State private var hit: ScoutHit?
    @State private var busy = false
    var key: String { name.lowercased() }

    var body: some View {
        Card("E-mail", symbol: "binoculars.fill", tint: .green) {
            HStack {
                TextField("Doména firmy", text: $domain, prompt: Text("firma.sk")).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onSubmit(find)
                Button(busy ? "Hľadám…" : "Nájsť e-mail", action: find).disabled(busy || domain.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            if let h = hit {
                if let e = h.email {
                    HStack(spacing: 6) {
                        Text(e).font(.body.weight(.medium)).textSelection(.enabled)
                        Text(h.label).font(.caption).foregroundStyle(h.tint)
                    }
                    if h.blocked == true { Text("V Nekontaktovať.").font(.caption).foregroundStyle(.red) }
                    if let alt = h.alternatives, !alt.isEmpty { Text("Alebo: \(alt.prefix(3).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 12) {
                        Button("Kopírovať") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e, forType: .string) }
                        Button("Napísať") { open("mailto:\(e)") }
                        if !note.contains(e) { Button("Do poznámky") { onSaveToNote(e) } }
                        Button("V Scoute") { open("scout://company/\(domain.trimmingCharacters(in: .whitespaces))") }
                    }
                    .buttonStyle(.link).font(.caption)
                } else {
                    Text(h.why ?? "Adresu sa nepodarilo nájsť.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { domain = (try? JSONDecoder().decode([String: String].self, from: Data(remembered.utf8)))?[key] ?? "" }
    }

    func find() {
        let d = domain.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        var map = (try? JSONDecoder().decode([String: String].self, from: Data(remembered.utf8))) ?? [:]
        map[key] = d
        remembered = String(data: (try? JSONEncoder().encode(map)) ?? Data(), encoding: .utf8) ?? "{}"
        busy = true
        Task {
            let r = await Task.detached { () -> ScoutHit in
                let p = Process(), out = Pipe(), err = Pipe()
                p.executableURL = URL(fileURLWithPath: Store.node)
                p.arguments = [NSHomeDirectory() + "/Developer/scout/src/cli.js", "person", name, d]
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { return ScoutHit(why: "Scout sa nepodarilo spustiť.") }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                _ = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (try? JSONDecoder().decode(ScoutHit.self, from: data)) ?? ScoutHit(why: "Scout nenašiel adresu (skontroluj doménu).")
            }.value
            busy = false
            hit = r
        }
    }
}
