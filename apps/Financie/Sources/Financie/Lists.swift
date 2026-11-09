import FinancieCore
import SwiftUI

/// Transactions of everything, a wallet or an account, by day, searchable.
struct TransactionsPage: View {
    @ObservedObject var model: AppModel
    let scope: Scope
    let title: String
    var account: Account?
    @State private var query = ""
    @State private var selection: Set<Int64> = []

    var body: some View {
        let _ = model.version
        let list = model.store.transactions(Store.Filter(accountIds: scope.accountId.map { [$0] }, walletId: scope.walletId, query: query, limit: 2000))
        let days = Dictionary(grouping: list, by: \.date)
        VStack(spacing: 0) {
            if let a = account { AccountHeader(account: a, model: model) }
            if list.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "Zatiaľ žiadne pohyby" : "Nič sa nenašlo", systemImage: "tray")
                } description: {
                    Text(query.isEmpty ? "Pridaj výdavok alebo príjem (⌘N). Brain ich vie zapísať aj z vety alebo fotky bločku." : "Skús iné slovo.")
                } actions: {
                    if query.isEmpty { Button("Pridať výdavok") { model.newTransaction(.expense) } }
                }
            } else {
                List(selection: $selection) {
                    ForEach(days.keys.sorted(by: >), id: \.self) { d in
                        Section {
                            ForEach(days[d]!) { t in
                                TxRow(t: t, model: model, showAccount: scope.accountId == nil).tag(t.id)
                                    .contextMenu {
                                        Button("Upraviť…") { model.edit(t) }
                                        Divider()
                                        Button("Zmazať", role: .destructive) { model.act { try model.store.deleteTransaction(t.id) } }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(Day.friendly(d))
                                Spacer()
                                Text(Money.string(days[d]!.filter { $0.kind != .transfer || scope.accountId != nil }.reduce(0) { $0 + $1.amountCents }, signed: true))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let t = model.store.transaction(id) { model.edit(t) }
                }
                .onDeleteCommand {
                    let ids = selection
                    model.act { for id in ids where model.store.transaction(id) != nil { try model.store.deleteTransaction(id) } }
                    selection = []
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Hľadať obchodníka, poznámku, kategóriu")
        .navigationTitle(title)
        .navigationSubtitle(account.map { "\($0.type.label) · \(model.wallet($0.walletId)?.name ?? "")" } ?? "\(list.count) pohybov")
    }
}

struct AccountHeader: View {
    let account: Account
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconBadge(symbol: account.type.symbol, color: account.type.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zostatok").font(.subheadline).foregroundStyle(.secondary)
                Text(Money.string(model.balances[account.id] ?? 0)).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                if !account.iban.isEmpty { Text(account.iban.chunked).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            Button { model.sheet = .reconcile(account) } label: { Label("Zosúladiť", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
                .help("Zadaj zostatok z banky, rozdiel sa zapíše ako korekcia")
            Button { model.sheet = .account(account) } label: { Label("Upraviť", systemImage: "pencil") }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension String {
    /// "SK3711000000002944157127" → "SK37 1100 0000 0029 4415 7127".
    var chunked: String { stride(from: 0, to: count, by: 4).map { i in String(dropFirst(i).prefix(4)) }.joined(separator: " ") }
}

struct TxRow: View {
    let t: Tx
    @ObservedObject var model: AppModel
    var showAccount = true

    var body: some View {
        let cat = model.category(t.categoryId)
        HStack(spacing: 12) {
            TxIcon(t: t, category: cat)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(cat)).lineLimit(1)
                Text(subtitle(cat)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if t.recurringId != nil { Image(systemName: "repeat").font(.caption).foregroundStyle(.tertiary).help("Z pravidelnej položky") }
            if t.source == "mcp" { Image(systemName: "brain").font(.caption).foregroundStyle(.tertiary).help("Zapísal Brain") }
            Amount(cents: t.amountCents, kind: t.kind)
        }
        .padding(.vertical, 3)
    }

    func title(_ c: TxCategory?) -> String {
        if !t.payee.isEmpty { return t.payee }
        if t.kind == .transfer, let o = model.store.counterpart(t) { return t.amountCents < 0 ? "Prevod na \(model.accountLabel(o.accountId))" : "Prevod z \(model.accountLabel(o.accountId))" }
        if t.kind == .adjustment { return "Korekcia zostatku" }
        return c?.name ?? t.kind.label
    }

    func subtitle(_ c: TxCategory?) -> String {
        var parts: [String] = []
        if !t.payee.isEmpty, let c { parts.append(c.name) }
        if t.kind == .transfer && !t.payee.isEmpty { parts.append("Prevod") }
        if !t.note.isEmpty { parts.append(t.note) }
        if showAccount { parts.append(model.accountLabel(t.accountId)) }
        return parts.isEmpty ? t.kind.label : parts.joined(separator: " · ")
    }
}

/// What recurring items still expect: late first, then the next weeks.
struct WaitingPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let late = model.expected.filter(\.isLate)
        let next = model.expected.filter { !$0.isLate }
        Group {
            if model.expected.isEmpty {
                ContentUnavailableView {
                    Label("Nič nečaká", systemImage: "checkmark.circle")
                } description: {
                    Text("Tu sa ukáže, čo podľa pravidelných položiek má prísť alebo odísť, a potvrdíš to jedným klikom.")
                } actions: { Button("Pridať pravidelnú položku") { model.newRecurring() } }
            } else {
                List {
                    if !late.isEmpty {
                        Section("Čaká na potvrdenie") { ForEach(late) { ExpectedRow(e: $0, model: model) } }
                    }
                    ForEach(months(next), id: \.0) { m, items in
                        Section(monthTitle(m)) { ForEach(items) { ExpectedRow(e: $0, model: model) } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Čaká")
        .navigationSubtitle(late.isEmpty ? "Najbližších 45 dní" : "\(late.count) na potvrdenie")
    }

    func months(_ items: [Expected]) -> [(String, [Expected])] {
        let g = Dictionary(grouping: items) { Day.month($0.dueDate) }
        return g.keys.sorted().map { ($0, g[$0]!) }
    }
}

struct ExpectedRow: View {
    let e: Expected
    @ObservedObject var model: AppModel
    var body: some View {
        let r = e.recurring
        let cat = model.category(r.categoryId)
        HStack(spacing: 12) {
            IconBadge(symbol: r.flow == .transfer ? "arrow.left.arrow.right" : cat?.symbol ?? (r.flow == .income ? "arrow.down" : "arrow.up"),
                      color: r.flow == .transfer ? .gray : .named(cat?.color ?? (r.flow == .income ? "green" : "gray")), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Day.friendly(e.dueDate))
                    if e.isLate { Text("· \(Day.diff(e.dueDate, Day.today)) dní").foregroundStyle(.orange) }
                    if r.mode != .fixed { Text("· \(r.mode == .composite ? "fix + variabilná" : r.mode == .variable ? "odhad" : "nepravidelná")") }
                    Text("· \(r.flow == .transfer ? "\(model.accountLabel(r.accountId)) → \(model.accountLabel(r.toAccountId ?? 0))" : model.accountLabel(r.accountId))")
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Amount(cents: r.flow == .transfer ? r.expectedCents : e.amountCents, kind: r.flow == .transfer ? .transfer : nil)
            Button("Potvrdiť") { model.sheet = .confirm(e) }.controlSize(.small)
            Menu {
                Button("Tentoraz nepríde (preskočiť)") { model.act { try model.store.skip(recurringId: r.id, dueDate: e.dueDate) } }
                Button("Upraviť položku…") { model.sheet = .recurring(r) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 5)
    }
}

/// The plan: recurring income, expenses and transfers with what they make per month.
struct RecurringPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let groups: [(Flow, [Recurring])] = [Flow.income, .expense, .transfer].map { f in (f, model.recurring.filter { $0.flow == f }) }.filter { !$0.1.isEmpty }
        let plan = model.store.plannedMonthly()
        Group {
            if model.recurring.isEmpty {
                ContentUnavailableView {
                    Label("Žiadne pravidelné položky", systemImage: "repeat")
                } description: {
                    Text("Plat, nájom, predplatné, energie, výplata z firmy. Fixné, variabilné, fix + variabilná zložka aj nepravidelné. Z nich vzniká prognóza a zoznam toho, čo čaká.")
                } actions: {
                    Button("Pravidelný príjem") { model.newRecurring(.income) }
                    Button("Pravidelný výdavok") { model.newRecurring(.expense) }
                }
            } else {
                List {
                    ForEach(groups, id: \.0) { flow, items in
                        Section {
                            ForEach(items) { r in
                                RecurringRow(r: r, model: model)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.sheet = .recurring(r) }
                                    .contextMenu {
                                        Button("Upraviť…") { model.sheet = .recurring(r) }
                                        Button(r.active ? "Pozastaviť" : "Obnoviť") { var x = r; x.active.toggle(); model.act { try model.store.saveRecurring(x) } }
                                        Divider()
                                        Button("Zmazať", role: .destructive) { model.act { try model.store.deleteRecurring(r.id) } }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(flow == .income ? "Príjmy" : flow == .expense ? "Výdavky" : "Prevody")
                                Spacer()
                                Text("\(Money.short(items.filter(\.active).reduce(0) { $0 + $1.monthlyCents })) / mes.").monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 24) {
                        Label("Príjmy \(Money.short(plan.income)) / mes.", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                        Label("Výdavky \(Money.short(plan.expense)) / mes.", systemImage: "arrow.up.circle.fill").foregroundStyle(.pink)
                        Spacer()
                        Text("Zostáva \(Money.short(plan.income - plan.expense)) mesačne").font(.headline.monospacedDigit())
                    }
                    .font(.callout)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Pravidelné")
        .navigationSubtitle("Plán príjmov a výdavkov")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Pravidelný príjem") { model.newRecurring(.income) }
                    Button("Pravidelný výdavok") { model.newRecurring(.expense) }
                    Button("Pravidelný prevod") { model.newRecurring(.transfer) }
                } label: { Label("Nová položka", systemImage: "repeat") }
            }
        }
    }
}

struct RecurringRow: View {
    let r: Recurring
    @ObservedObject var model: AppModel
    var body: some View {
        let cat = model.category(r.categoryId)
        let next = model.expected.first { $0.recurring.id == r.id }
        HStack(spacing: 12) {
            IconBadge(symbol: r.flow == .transfer ? "arrow.left.arrow.right" : cat?.symbol ?? "repeat",
                      color: r.flow == .transfer ? .gray : .named(cat?.color ?? "gray"), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                Text(describe(r) + (next.map { " · ďalej \(Day.friendly($0.dueDate).lowercased())" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText(r)).monospacedDigit()
                if r.frequency != .monthly && r.frequency != .once { Text("≈ \(Money.short(r.monthlyCents)) / mes.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
        .opacity(r.active ? 1 : 0.45)
    }

    func amountText(_ r: Recurring) -> String {
        switch r.mode {
        case .composite: "\(Money.string(r.amountCents)) + ~\(Money.short(r.variableCents))"
        case .variable, .irregular: "~\(Money.string(r.amountCents))"
        case .fixed: Money.string(r.amountCents)
        }
    }
}

/// "Každý mesiac 10. · fix + variabilná · Tatra".
func describe(_ r: Recurring) -> String {
    var when: String
    switch r.frequency {
    case .once: when = "Raz \(Day.sk(r.startDate))"
    case .weekly: when = r.interval > 1 ? "Každý \(r.interval). týždeň" : "Každý týždeň"
    case .monthly: when = (r.interval > 1 ? "Každý \(r.interval). mesiac" : "Mesačne") + (r.day >= 31 ? ", posledný deň" : ", \(r.day).")
    case .quarterly: when = "Štvrťročne, \(r.day)."
    case .yearly: when = "Ročne, \(r.day). \(Day.monthName(Day.month(r.startDate), year: false))"
    }
    if !r.active { when += " · pozastavené" }
    if let e = r.endDate { when += " · do \(Day.sk(e))" }
    return when
}
