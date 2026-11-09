import FinancieCore
import SwiftUI

struct SheetView: View {
    let sheet: Sheet
    @ObservedObject var model: AppModel
    var body: some View {
        switch sheet {
        case .transaction(let t, let f): TransactionEditor(model: model, original: t, flow: f)
        case .account(let a): AccountEditor(model: model, account: a)
        case .wallet(let w): WalletEditor(model: model, wallet: w)
        case .recurring(let r): RecurringEditor(model: model, item: r)
        case .reconcile(let a): ReconcileSheet(model: model, account: a)
        case .confirm(let e): ConfirmSheet(model: model, e: e)
        }
    }
}

/// The shell every sheet uses: a title, a form, Cancel and the main button.
struct SheetForm<Content: View>: View {
    let title: String
    let action: String
    var canSave = true
    var destructive: (label: String, run: () -> Void)?
    let save: () -> Bool
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 18)
            Form { content }.formStyle(.grouped).scrollContentBackground(.hidden)
            HStack {
                if let d = destructive { Button(d.label, role: .destructive) { d.run(); dismiss() } }
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { if save() { dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 4)
        }
        .frame(width: 480)
    }
}

/// Accounts grouped by wallet, for pickers.
struct AccountPicker: View {
    let title: String
    @Binding var id: Int64
    @ObservedObject var model: AppModel
    var body: some View {
        Picker(title, selection: $id) {
            ForEach(model.wallets) { w in
                Section(w.name) {
                    ForEach(model.accounts(in: w)) { a in Label(a.name, systemImage: a.type.symbol).tag(a.id) }
                }
            }
        }
    }
}

struct CategoryPicker: View {
    @Binding var id: Int64?
    let flow: Flow
    @ObservedObject var model: AppModel
    var body: some View {
        Picker("Kategória", selection: $id) {
            Text("Bez kategórie").tag(Int64?.none)
            ForEach(model.categories.filter { $0.flow == flow && (!$0.archived || $0.id == id) }) { c in
                Label(c.name, systemImage: c.symbol).tag(Int64?.some(c.id))
            }
        }
    }
}

struct DateField: View {
    let title: String
    @Binding var day: String
    var body: some View {
        DatePicker(title, selection: Binding(get: { Day.date(day) }, set: { day = Day.string($0) }), displayedComponents: .date)
    }
}

// MARK: Tx

struct TransactionEditor: View {
    @ObservedObject var model: AppModel
    let original: Tx
    @State var flow: Flow
    @State private var t: Tx
    @State private var cents: Int?
    @State private var toAccount: Int64 = 0

    init(model: AppModel, original: Tx, flow: Flow) {
        self.model = model
        self.original = original
        _flow = State(initialValue: flow)
        _t = State(initialValue: original)
        _cents = State(initialValue: original.amountCents == 0 ? nil : abs(original.amountCents))
        let other = model.store.counterpart(original)
        let from = original.kind == .transfer && original.amountCents > 0 ? other?.accountId : original.accountId
        let to = original.kind == .transfer ? (original.amountCents > 0 ? original.accountId : other?.accountId) : nil
        _t = State(initialValue: { var x = original; x.accountId = from ?? original.accountId; return x }())
        _toAccount = State(initialValue: to ?? model.accounts.first { $0.id != original.accountId }?.id ?? 0)
    }

    var isNew: Bool { original.id == 0 }

    var body: some View {
        SheetForm(title: isNew ? "Nový \(flow == .transfer ? "prevod" : flow == .income ? "príjem" : "výdavok")" : "Upraviť pohyb",
                  action: isNew ? "Pridať" : "Uložiť", canSave: (cents ?? 0) > 0,
                  destructive: isNew ? nil : ("Zmazať", { model.act { try model.store.deleteTransaction(original.id) } }), save: save) {
            if isNew || original.kind != .transfer {
                Picker("Druh", selection: $flow) {
                    Text("Výdavok").tag(Flow.expense)
                    Text("Príjem").tag(Flow.income)
                    if isNew { Text("Prevod").tag(Flow.transfer) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            MoneyField(title: "Suma", cents: $cents, large: true)
            if flow == .transfer {
                AccountPicker(title: "Z účtu", id: $t.accountId, model: model)
                AccountPicker(title: "Na účet", id: $toAccount, model: model)
            } else {
                AccountPicker(title: "Účet", id: $t.accountId, model: model)
                CategoryPicker(id: $t.categoryId, flow: flow, model: model)
                TextField(flow == .income ? "Od koho" : "Komu / kde", text: $t.payee, prompt: Text(flow == .income ? "Zamestnávateľ, klient" : "Obchod, služba"))
            }
            DateField(title: "Dátum", day: $t.date)
            TextField("Poznámka", text: $t.note, prompt: Text("Nepovinné"))
        }
        .onChange(of: flow) { _, f in
            if let c = t.categoryId, model.category(c)?.flow != f { t.categoryId = nil }
        }
    }

    func save() -> Bool {
        guard let c = cents, c > 0 else { return false }
        var ok = false
        model.act {
            if flow == .transfer {
                if isNew {
                    try model.store.transfer(from: t.accountId, to: toAccount, cents: c, date: t.date, note: t.note)
                } else {
                    var x = original
                    x.date = t.date; x.note = t.note
                    x.amountCents = original.amountCents < 0 ? -c : c
                    try model.store.updateTransaction(x)
                }
            } else {
                var x = t
                x.kind = flow == .income ? .income : .expense
                x.amountCents = c
                if isNew { try model.store.addTransaction(x) } else { try model.store.updateTransaction(x) }
            }
            ok = true
        }
        return ok
    }
}

// MARK: Account and wallet

struct AccountEditor: View {
    @ObservedObject var model: AppModel
    @State var account: Account
    @State private var opening: Int?
    @State private var negative = false

    init(model: AppModel, account: Account) {
        self.model = model
        _account = State(initialValue: account)
        _opening = State(initialValue: abs(account.openingCents))
        _negative = State(initialValue: account.openingCents < 0)
    }

    var body: some View {
        SheetForm(title: account.id == 0 ? "Nový účet" : "Upraviť účet", action: account.id == 0 ? "Pridať" : "Uložiť",
                  canSave: !account.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  destructive: account.id == 0 ? nil : (account.archived ? "Obnoviť" : "Archivovať", {
                      var a = account; a.archived.toggle(); model.act { try model.store.saveAccount(a) }
                  }), save: save) {
            TextField("Názov", text: $account.name, prompt: Text("Tatra, Revolut, Hotovosť"))
            Picker("Peňaženka", selection: $account.walletId) { ForEach(model.wallets) { Text($0.name).tag($0.id) } }
            Picker("Druh", selection: $account.type) { ForEach(AccountType.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) } }
            if account.type != .cash { TextField("IBAN", text: $account.iban, prompt: Text("Nepovinné")) }
            Section {
                MoneyField(title: "Počiatočný zostatok", cents: $opening)
                Toggle("V mínuse (kreditka, debet)", isOn: $negative)
                DateField(title: "K dátumu", day: $account.openingDate)
            } footer: {
                Text("Zostatok na začiatku tohto dňa. Potom ho kedykoľvek zosúladíš so zostatkom v banke.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func save() -> Bool {
        var ok = false
        var a = account
        a.openingCents = (opening ?? 0) * (negative ? -1 : 1)
        model.act { let s = try model.store.saveAccount(a); if account.id == 0 { model.page = .account(s.id) }; ok = true }
        return ok
    }
}

struct WalletEditor: View {
    @ObservedObject var model: AppModel
    @State var wallet: Wallet
    var body: some View {
        SheetForm(title: wallet.id == 0 ? (wallet.kind == .business ? "Nová firma" : "Nová peňaženka") : "Peňaženka", action: wallet.id == 0 ? "Pridať" : "Uložiť",
                  canSave: !wallet.name.trimmingCharacters(in: .whitespaces).isEmpty, save: {
                      var ok = false
                      model.act { try model.store.saveWallet(wallet); ok = true }
                      return ok
                  }) {
            TextField("Názov", text: $wallet.name)
            Picker("Druh", selection: $wallet.kind) { ForEach(WalletKind.allCases, id: \.self) { Text($0.label).tag($0) } }
            if wallet.fakturyCompanyId != nil {
                Text("Prepojené s Faktúrami: názov sa berie odtiaľ.").font(.caption).foregroundStyle(.secondary)
            } else if wallet.kind == .business {
                Text("Firmy z Faktúr sa pridávajú samy. Túto pridaj, len ak vo Faktúrach nie je.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Recurring

struct RecurringEditor: View {
    @ObservedObject var model: AppModel
    @State var item: Recurring
    @State private var amount: Int?
    @State private var variable: Int?
    @State private var hasEnd = false

    init(model: AppModel, item: Recurring) {
        self.model = model
        _item = State(initialValue: item)
        _amount = State(initialValue: item.amountCents == 0 ? nil : item.amountCents)
        _variable = State(initialValue: item.variableCents == 0 ? nil : item.variableCents)
        _hasEnd = State(initialValue: item.endDate != nil)
    }

    var body: some View {
        SheetForm(title: item.id == 0 ? "Nová pravidelná položka" : "Pravidelná položka", action: item.id == 0 ? "Pridať" : "Uložiť",
                  canSave: !item.name.trimmingCharacters(in: .whitespaces).isEmpty && ((amount ?? 0) > 0 || (variable ?? 0) > 0),
                  destructive: item.id == 0 ? nil : ("Zmazať", { model.act { try model.store.deleteRecurring(item.id) } }), save: save) {
            Picker("Druh", selection: $item.flow) {
                Text("Výdavok").tag(Flow.expense)
                Text("Príjem").tag(Flow.income)
                Text("Prevod").tag(Flow.transfer)
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField("Názov", text: $item.name, prompt: Text(item.flow == .income ? "Plat, nájomné od…" : item.flow == .transfer ? "Výplata z firmy" : "Nájom, Netflix, elektrina"))
            Section {
                Picker("Suma", selection: $item.mode) { ForEach(RecurringMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                MoneyField(title: item.mode == .composite ? "Fixná časť" : item.mode == .fixed ? "Suma" : "Odhad sumy", cents: $amount)
                if item.mode == .composite { MoneyField(title: "Obvyklá variabilná časť", cents: $variable) }
            } footer: { Text(item.mode.help).font(.caption).foregroundStyle(.secondary) }
            Section {
                Picker("Opakovanie", selection: $item.frequency) {
                    ForEach(item.mode == .irregular ? [Frequency.once, .yearly] : Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if item.frequency != .once {
                    Stepper("Každý \(item.interval). \(unit)", value: $item.interval, in: 1...12)
                }
                if [.monthly, .quarterly, .yearly].contains(item.frequency) {
                    Stepper(item.day >= 31 ? "Posledný deň v mesiaci" : "\(item.day). deň v mesiaci", value: $item.day, in: 1...31)
                }
                DateField(title: item.frequency == .once ? "Kedy" : "Od", day: $item.startDate)
                if item.frequency != .once {
                    Toggle("Má koniec", isOn: $hasEnd)
                    if hasEnd { DateField(title: "Do", day: Binding(get: { item.endDate ?? Day.adding(months: 12, to: item.startDate) }, set: { item.endDate = $0 })) }
                }
            } footer: { Text(preview).font(.caption).foregroundStyle(.secondary) }
            Section {
                if item.flow == .transfer {
                    AccountPicker(title: "Z účtu", id: $item.accountId, model: model)
                    AccountPicker(title: "Na účet", id: Binding(get: { item.toAccountId ?? 0 }, set: { item.toAccountId = $0 }), model: model)
                } else {
                    AccountPicker(title: "Účet", id: $item.accountId, model: model)
                    CategoryPicker(id: $item.categoryId, flow: item.flow, model: model)
                    TextField(item.flow == .income ? "Od koho" : "Komu", text: $item.payee, prompt: Text("Nepovinné"))
                }
                TextField("Poznámka", text: $item.note, prompt: Text("Nepovinné"))
                if item.id != 0 { Toggle("Aktívna", isOn: $item.active) }
            }
        }
        .onChange(of: item.flow) { _, f in
            if let c = item.categoryId, model.category(c)?.flow != f { item.categoryId = nil }
            if f == .transfer, item.toAccountId == nil { item.toAccountId = model.accounts.first { $0.id != item.accountId }?.id }
        }
        .onChange(of: item.mode) { _, m in if m == .irregular, ![.once, .yearly].contains(item.frequency) { item.frequency = .once } }
    }

    var unit: String {
        switch item.frequency {
        case .weekly: "týždeň"
        case .monthly: "mesiac"
        case .quarterly: "štvrťrok"
        case .yearly: "rok"
        case .once: ""
        }
    }

    /// The next dates and the monthly equivalent, so the plan is easy to check.
    var preview: String {
        var r = item
        r.amountCents = amount ?? 0
        r.variableCents = variable ?? 0
        if !hasEnd { r.endDate = nil }
        let dates = Schedule.dates(r, from: max(Day.today, r.startDate), to: Day.adding(days: 800, to: Day.today)).prefix(3)
        var s = dates.isEmpty ? "V budúcnosti už nepríde." : "Najbližšie: " + dates.map(Day.sk).joined(separator: ", ")
        if r.frequency != .once, r.expectedCents > 0 { s += "\nMesačne približne \(Money.string(r.monthlyCents))." }
        return s
    }

    func save() -> Bool {
        var r = item
        r.amountCents = amount ?? 0
        r.variableCents = variable ?? 0
        if !hasEnd { r.endDate = nil }
        var ok = false
        model.act { try model.store.saveRecurring(r); ok = true }
        return ok
    }
}

// MARK: Confirm and reconcile

struct ConfirmSheet: View {
    @ObservedObject var model: AppModel
    let e: Expected
    @State private var cents: Int?
    @State private var day: String
    @State private var account: Int64

    init(model: AppModel, e: Expected) {
        self.model = model
        self.e = e
        _cents = State(initialValue: e.recurring.expectedCents)
        _day = State(initialValue: min(e.dueDate, Day.today))
        _account = State(initialValue: e.recurring.accountId)
    }

    var body: some View {
        SheetForm(title: "Potvrdiť: \(e.recurring.name)", action: "Potvrdiť", canSave: (cents ?? 0) > 0, save: {
            var ok = false
            model.act { try model.store.confirm(recurringId: e.recurring.id, dueDate: e.dueDate, amountCents: cents, date: day, accountId: account); ok = true }
            return ok
        }) {
            Section {
                MoneyField(title: e.recurring.mode == .fixed ? "Suma" : "Skutočná suma", cents: $cents, large: true)
                DateField(title: "Dátum", day: $day)
                AccountPicker(title: e.recurring.flow == .transfer ? "Z účtu" : "Účet", id: $account, model: model)
            } footer: {
                Text("Plán: \(Money.string(e.recurring.expectedCents)) k \(Day.sk(e.dueDate)). \(e.recurring.mode == .fixed ? "" : "Zadaj, koľko naozaj prišlo alebo odišlo.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ReconcileSheet: View {
    @ObservedObject var model: AppModel
    let account: Account
    @State private var cents: Int?
    @State private var negative = false
    @State private var day = Day.today

    var body: some View {
        let now = model.store.balance(account.id, through: day)
        let target = (cents ?? 0) * (negative ? -1 : 1)
        SheetForm(title: "Zosúladiť \(account.name)", action: "Zosúladiť", canSave: cents != nil, save: {
            var ok = false
            model.act { try model.store.reconcile(accountId: account.id, balanceCents: target, date: day); ok = true }
            return ok
        }) {
            Section {
                LabeledContent("Financie ukazujú", value: Money.string(now))
                MoneyField(title: "Zostatok v banke", cents: $cents, large: true)
                Toggle("V mínuse", isOn: $negative)
                DateField(title: "K dátumu", day: $day)
            } footer: {
                if cents != nil {
                    let diff = target - now
                    Text(diff == 0 ? "Sedí na cent, nič sa nezapíše." : "Zapíše sa korekcia \(Money.string(diff, signed: true)).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
