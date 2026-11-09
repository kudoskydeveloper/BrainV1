import SwiftUI

// MARK: Dnes

/// What needs you today across both businesses: tasks due or late, open deals with no next step (or a late one), new leads.
struct TodayView: View {
    let data: Overview
    let query: String
    @Binding var pick: Pick?

    var body: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let tasks = data.businesses.flatMap { b in b.tasks.map { (b, $0) } }
            .filter { _, t in (t.due.flatMap(Fmt.day).map { $0 <= today } ?? false) && (query.isEmpty || matches(query, t.title)) }
            .sorted { ($0.1.due ?? "") < ($1.1.due ?? "") }
        let stale = data.businesses.flatMap { b in b.openDeals.filter(\.stale).map { (b, $0) } }
            .filter { _, d in query.isEmpty || matches(query, "\(d.title) \(d.account ?? "")") }
        let leads = data.businesses.flatMap { b in b.leads.filter { $0.status == "new" || $0.overdue }.map { (b, $0) } }
            .filter { _, l in query.isEmpty || matches(query, "\(l.name) \(l.contact?.name ?? "")") }
        Page {
            StatsRow(data: data)
            Card("Úlohy na dnes a po termíne", symbol: "checklist", tint: .purple) {
                if tasks.isEmpty { Text("Nič nečaká. 🎉").foregroundStyle(.secondary) }
                ForEach(tasks, id: \.1.id) { b, t in
                    TaskRow(b: b, t: t).contentShape(.rect).onTapGesture { open(b, accountFor(b, t)) }
                }
            }
            Card("Obchody bez kroku alebo s krokom po termíne", symbol: "exclamationmark.bubble.fill", tint: .orange) {
                if stale.isEmpty { Text("Každý otvorený obchod má naplánovaný krok.").foregroundStyle(.secondary) }
                ForEach(stale, id: \.1.id) { b, d in
                    DealRow(b: b, d: d, showBusiness: true).contentShape(.rect).onTapGesture { open(b, d.accountId) }
                }
            }
            if !leads.isEmpty {
                Card("Nové leady", symbol: "person.crop.circle.badge.plus", tint: .green) {
                    ForEach(leads.prefix(12), id: \.1.id) { b, l in
                        LeadRow(l: l).contentShape(.rect).onTapGesture { open(b, l.id) }
                    }
                    if leads.count > 12 { Text("a ďalších \(leads.count - 12) v Leadoch").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Dnes")
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.sk)))
    }

    func accountFor(_ b: Business, _ t: CRMTask) -> String? { t.accountId ?? b.deals.first { $0.id == t.dealId }?.accountId }
    func open(_ b: Business, _ account: String?) { if let account { pick = Pick(business: b.id, account: account) } }
}

struct StatsRow: View {
    let data: Overview
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], spacing: 12) {
            ForEach(data.businesses) { b in
                StatTile("\(b.name): otvorené", Fmt.money(b.pipelineValue), detail: "\(b.openDeals.count) obchodov\(b.id == "kudosky" ? " · MRR × 12" : "")", symbol: "rectangle.split.3x1.fill", tint: b.tint)
            }
            let won = data.businesses.flatMap { b in b.deals.filter { b.stage($0.stage)?.kind == "won" } }
            StatTile("Vyhraté", "\(won.count)", detail: Fmt.money(won.reduce(0) { $0 + ($1.value ?? 0) + ($1.mrr ?? 0) * 12 }), symbol: "trophy.fill", tint: .green)
        }
    }
}

struct TaskRow: View {
    let b: Business
    let t: CRMTask
    var body: some View {
        HStack(spacing: 10) {
            TaskCheck(b: b, task: t.id, deal: t.dealId, account: t.accountId, overdue: Fmt.overdue(t.due))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).lineLimit(2)
                HStack(spacing: 6) {
                    BusinessDot(b: b)
                    if let a = b.account(t.accountId) ?? b.deals.first(where: { $0.id == t.dealId }).flatMap({ b.account($0.accountId) }) {
                        Text(a.name).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(Fmt.due(t.due)).font(.caption).foregroundStyle(Fmt.overdue(t.due) ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }
}

struct BusinessDot: View {
    let b: Business
    var body: some View {
        Text(b.name).font(.caption2.weight(.semibold)).foregroundStyle(b.tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(b.tint.opacity(0.13), in: .capsule)
    }
}

struct DealRow: View {
    let b: Business
    let d: Deal
    var showBusiness = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showBusiness { BusinessDot(b: b) }
                    Text(d.title).font(.body.weight(.medium)).lineLimit(1)
                }
                Text([d.account, b.stage(d.stage)?.label].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let n = d.nextStep {
                    Text("Ďalej: \(n)").font(.caption).foregroundStyle(d.stale ? .orange : .secondary).lineLimit(2)
                } else {
                    Text("Bez ďalšieho kroku").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(d.amount).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

// MARK: Pipeline

/// The board: a column per open stage, won and lost at the end. Cards open the client.
struct PipelineBoard: View {
    let b: Business
    let query: String
    @Binding var pick: Pick?
    @State private var showClosed = false
    @State private var target: String?
    @EnvironmentObject private var editing: Editing
    @ObservedObject private var store = Store.shared

    var body: some View {
        let deals = b.deals.filter { query.isEmpty || matches(query, "\($0.title) \($0.account ?? "")") }
        let columns = showClosed ? b.stages : b.openStages
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { st in
                    let list = deals.filter { $0.stage == st.key }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(st.label).font(.headline).foregroundStyle(st.kind == "open" ? Color.primary : st.tint)
                            Text("\(list.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.money(list.reduce(0) { $0 + ($1.value ?? 0) + ($1.mrr ?? 0) * 12 })).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(list) { d in
                                    DealCard(b: b, d: d, selected: pick?.account == d.accountId)
                                        .onTapGesture { if let a = d.accountId { pick = Pick(business: b.id, account: a) } }
                                        .draggable(d.id) { DealCard(b: b, d: d).frame(width: 236).opacity(0.9) }
                                        .contextMenu { DealMenu(b: b, d: d) }
                                }
                                if list.isEmpty { Text("Prázdne").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 20) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 260)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: target == st.key ? 2 : 0))
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first else { return false }
                        Moves.drop(id, on: st, in: b, store: store, editing: editing)
                        return true
                    } isTargeted: { on in target = on ? st.key : (target == st.key ? nil : target) }
                }
            }
            .padding(16)
        }
        .navigationTitle("\(b.name) · Pipeline")
        .overlay(alignment: .topTrailing) { if store.saving { ProgressView().controlSize(.small).padding(20) } }
        .navigationSubtitle("\(b.openDeals.count) otvorených · \(Fmt.money(b.pipelineValue))")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showClosed) { Label("Uzavreté", systemImage: "archivebox") }
                    .help("Ukázať aj vyhraté a prehraté")
            }
        }
    }
}

struct DealCard: View {
    let b: Business
    let d: Deal
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.title).font(.callout.weight(.semibold)).lineLimit(3)
            if let a = d.account, !a.isEmpty { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                if !d.amount.isEmpty { Text(d.amount).font(.caption.weight(.semibold)).monospacedDigit() }
                Spacer()
                if let on = d.nextStepOn { Label(Fmt.due(on), systemImage: "calendar").font(.caption2).foregroundStyle(Fmt.overdue(on) ? .red : .secondary) }
            }
            if let n = d.nextStep {
                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if b.stage(d.stage)?.kind == "open" {
                Label("Bez ďalšieho kroku", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 0.5))
        .contentShape(.rect)
    }
}

// MARK: Klienti

struct AccountsTable: View {
    let b: Business
    let query: String
    @Binding var pick: Pick?
    @State private var selection: Account.ID?
    @State private var sort = [KeyPathComparator(\Row.updated, order: .reverse)]

    struct Row: Identifiable {
        let id: String
        let name: String
        let lifecycle: String
        let domain: String
        let deals: Int
        let open: String
        let updated: String
    }

    var body: some View {
        let rows = b.accounts.filter { query.isEmpty || matches(query, "\($0.name) \($0.domain ?? "") \($0.ref ?? "")") }.map { a in
            let ds = b.deals.filter { $0.accountId == a.id }
            let open = ds.filter { b.stage($0.stage)?.kind == "open" }
            return Row(id: a.id, name: a.name, lifecycle: .lifecycleLabel(a.lifecycle), domain: a.domain ?? "", deals: ds.count,
                       open: open.isEmpty ? "" : Fmt.money(open.reduce(0) { $0 + ($1.value ?? 0) + ($1.mrr ?? 0) * 12 }), updated: String((a.updatedAt ?? "").prefix(10)))
        }.sorted(using: sort)
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Klient", value: \.name) { r in Text(r.name).font(.body.weight(.medium)) }
            TableColumn("Fáza", value: \.lifecycle).width(min: 70, ideal: 90)
            TableColumn("Web", value: \.domain).width(min: 100, ideal: 160)
            TableColumn("Obchody", value: \.deals) { r in Text(r.deals == 0 ? "" : "\(r.deals)").monospacedDigit() }.width(60)
            TableColumn("Otvorené", value: \.open) { r in Text(r.open).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Zmena", value: \.updated) { r in Text(Fmt.day(r.updated).map(Fmt.date) ?? "").foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
        }
        .onChange(of: selection) { _, id in if let id { pick = Pick(business: b.id, account: id) } }
        .navigationTitle("\(b.name) · Klienti")
        .navigationSubtitle("\(rows.count)\(b.id == "kudosky" && b.accounts.count >= 50 ? " (prvých 50)" : "")")
    }
}

// MARK: Úlohy

struct TasksView: View {
    let b: Business
    let query: String
    @Binding var pick: Pick?

    var body: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let week = Calendar.current.date(byAdding: .day, value: 7, to: today)!
        let all = b.tasks.filter { query.isEmpty || matches(query, $0.title) }.sorted { ($0.due ?? "9") < ($1.due ?? "9") }
        let groups: [(String, [CRMTask])] = [
            ("Po termíne", all.filter { $0.due.flatMap(Fmt.day).map { $0 < today } ?? false }),
            ("Dnes", all.filter { $0.due.flatMap(Fmt.day).map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false }),
            ("Tento týždeň", all.filter { $0.due.flatMap(Fmt.day).map { $0 > today && $0 <= week } ?? false }),
            ("Neskôr", all.filter { $0.due.flatMap(Fmt.day).map { $0 > week } ?? false }),
            ("Bez termínu", all.filter { $0.due == nil }),
        ].filter { !$0.1.isEmpty }
        Group {
            if all.isEmpty {
                ContentUnavailableView("Žiadne otvorené úlohy", systemImage: "checkmark.circle", description: Text("V \(b.name) nečaká nič."))
            } else {
                List {
                    ForEach(groups, id: \.0) { title, list in
                        Section(title) {
                            ForEach(list) { t in
                                TaskRow(b: b, t: t).contentShape(.rect).onTapGesture {
                                    if let a = t.accountId ?? b.deals.first(where: { $0.id == t.dealId })?.accountId { pick = Pick(business: b.id, account: a) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("\(b.name) · Úlohy")
        .navigationSubtitle("\(all.count) otvorených")
    }
}

// MARK: Leady (Kuboard)

struct LeadRow: View {
    let l: Lead
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: l.contact?.name.isEmpty == false ? l.contact!.name : l.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name).font(.body.weight(.medium)).lineLimit(1)
                Text([l.contact?.name, l.contact?.position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let t = l.nextTask?.title {
                    Text("Ďalej: \(t)").font(.caption).foregroundStyle(l.overdue ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(l.statusLabel).font(.caption.weight(.semibold)).foregroundStyle(l.status == "new" ? .green : .secondary)
                if let s = l.source { Text(s).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct LeadsTable: View {
    let b: Business
    let query: String
    @Binding var pick: Pick?
    @State private var selection: Lead.ID?

    var body: some View {
        let leads = b.leads.filter { query.isEmpty || matches(query, "\($0.name) \($0.contact?.name ?? "") \($0.source ?? "")") }
        let groups: [(String, [Lead])] = [("Nové", leads.filter { $0.status == "new" }), ("Oslovené", leads.filter { $0.status == "contacted" }),
                                          ("V kontakte", leads.filter { $0.status == "engaged" }), ("Ostatné", leads.filter { !["new", "contacted", "engaged"].contains($0.status ?? "") })]
            .filter { !$0.1.isEmpty }
        List(selection: $selection) {
            ForEach(groups, id: \.0) { title, list in
                Section("\(title) · \(list.count)") { ForEach(list) { l in LeadRow(l: l).tag(l.id) } }
            }
        }
        .onChange(of: selection) { _, id in if let id { pick = Pick(business: b.id, account: id) } }
        .navigationTitle("\(b.name) · Leady")
        .navigationSubtitle("\(leads.count)")
    }
}

/// Right-click on a deal: next step, move, note, task, edit.
struct DealMenu: View {
    let b: Business
    let d: Deal
    @EnvironmentObject private var editing: Editing
    var body: some View {
        Button { editing.editor = .nextStep(b, d) } label: { Label("Ďalší krok…", systemImage: "arrow.forward.circle") }
        Menu {
            ForEach(b.stages.filter { $0.key != d.stage }) { st in
                Button(st.label) {
                    if st.kind == "lost" { editing.editor = .lostReason(b, d, st.key) } else { Moves.move(d, to: st.key, in: b, store: .shared) }
                }
            }
        } label: { Label("Presunúť do", systemImage: "arrow.left.arrow.right") }
        Divider()
        Button { editing.editor = .note(b, account: d.accountId, deal: d) } label: { Label("Poznámka…", systemImage: "text.bubble") }
        Button { editing.editor = .task(b, account: d.accountId, deal: d) } label: { Label("Úloha…", systemImage: "checklist") }
        if let a = d.accountId { Button { editing.editor = .deal(b, account: a, d) } label: { Label("Upraviť obchod…", systemImage: "pencil") } }
        if b.id == "10t", b.stage(d.stage)?.kind == "won", (d.value ?? 0) > 0 {
            Divider()
            Button { Invoicing.draft(d) } label: { Label("Koncept faktúry vo Faktúrach", systemImage: "eurosign.circle") }
        }
    }
}

/// A task's checkbox: done at once (the row disappears; it comes back if the CRM refuses).
struct TaskCheck: View {
    let b: Business
    let task: String
    var deal: String?
    var account: String?
    var overdue = false
    var body: some View {
        Button {
            var a: [String: Any] = ["task": task]
            if let deal { a["deal"] = deal }
            Store.shared.act(b.id, "task_done", a, done: "Splnené", reload: account) { o in
                guard let bi = o.businesses.firstIndex(where: { $0.id == b.id }) else { return }
                o.businesses[bi].tasks.removeAll { $0.id == task }
            }
        } label: {
            Image(systemName: "circle").foregroundStyle(overdue ? .red : .secondary).font(.body)
        }
        .buttonStyle(.plain)
        .help("Označiť ako splnené")
    }
}

enum Invoicing {
    /// A won 10T deal → an invoice draft in Faktúry (10T Studios, the client's IČO, one line with the deal); Faktúry opens on it.
    @MainActor static func draft(_ d: Deal) {
        var a: [String: Any] = ["deal": d.ref ?? d.id]
        if let acc = d.accountId { a["account"] = acc }
        Store.shared.act("10t", "invoice_draft", a, done: "Koncept faktúry je vo Faktúrach: \(d.title)", reload: d.accountId)
    }
}
