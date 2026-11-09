import FinancieCore
import Foundation

// financie-mcp: stdio MCP server (JSON-RPC, one message per line) over the Financie database. Works while the app is closed
// or locked (Touch ID guards only the window); the app picks up changes by itself. Writes are plain MCP write tools, so Brain
// shows them as proposals for the user's yes.

setvbuf(stdout, nil, _IOLBF, 0)
let store: Store
do { store = try Store() } catch {
    FileHandle.standardError.write(Data("financie-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
store.actor = "mcp"
_ = try? FakturyLink.sync(store)

struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write(Data([0x0A]))
}

// MARK: JSON shapes

func euros(_ c: Int) -> Double { Double(c) / 100 }
func cents(_ v: Any?) -> Int? {
    if let n = v as? NSNumber { return Int((n.doubleValue * 100).rounded(.toNearestOrAwayFromZero)) }
    if let s = v as? String { return Money.parse(s) }
    return nil
}
func str(_ a: [String: Any], _ k: String) -> String? {
    if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
    if let n = a[k] as? NSNumber { return n.stringValue }
    return nil
}
func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value ?? (v as? String).flatMap { Int64($0) } }
func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

var walletsById: [Int64: Wallet] { Dictionary(uniqueKeysWithValues: store.wallets(includeArchived: true).map { ($0.id, $0) }) }
var accountsById: [Int64: Account] { Dictionary(uniqueKeysWithValues: store.accounts(includeArchived: true).map { ($0.id, $0) }) }
var categoriesById: [Int64: TxCategory] { Dictionary(uniqueKeysWithValues: store.categories(includeArchived: true).map { ($0.id, $0) }) }

func walletJSON(_ w: Wallet) -> [String: Any] {
    var d: [String: Any] = ["id": w.id, "name": w.name, "kind": w.kind.rawValue, "balance": euros(store.balance(Scope(walletId: w.id)))]
    if let c = w.fakturyCompanyId { d["faktury_company_id"] = c }
    if w.archived { d["archived"] = true }
    return d
}

func accountJSON(_ a: Account) -> [String: Any] {
    var d: [String: Any] = ["id": a.id, "name": a.name, "wallet": walletsById[a.walletId]?.name ?? "", "wallet_id": a.walletId, "type": a.type.rawValue,
                            "currency": a.currency, "balance": euros(store.balance(a.id)), "opening_balance": euros(a.openingCents), "opening_date": a.openingDate]
    if !a.iban.isEmpty { d["iban"] = a.iban }
    if a.archived { d["archived"] = true }
    return d
}

func txJSON(_ t: Tx) -> [String: Any] {
    var d: [String: Any] = ["id": t.id, "date": t.date, "amount": euros(t.amountCents), "kind": t.kind.rawValue,
                            "account": accountsById[t.accountId]?.name ?? "", "account_id": t.accountId]
    if let c = t.categoryId { d["category"] = categoriesById[c]?.name ?? "" }
    if !t.payee.isEmpty { d["payee"] = t.payee }
    if !t.note.isEmpty { d["note"] = t.note }
    if let o = store.counterpart(t) { d["other_account"] = accountsById[o.accountId]?.name ?? "" }
    if let r = t.recurringId { d["recurring_id"] = r; d["due_date"] = t.dueDate ?? "" }
    if t.source != "manual" { d["source"] = t.source }
    return d
}

func recurringJSON(_ r: Recurring) -> [String: Any] {
    var d: [String: Any] = ["id": r.id, "name": r.name, "flow": r.flow.rawValue, "mode": r.mode.rawValue, "amount": euros(r.amountCents),
                            "expected_amount": euros(r.expectedCents), "monthly_equivalent": euros(r.monthlyCents), "frequency": r.frequency.rawValue,
                            "interval": r.interval, "day": r.day, "start_date": r.startDate, "account": accountsById[r.accountId]?.name ?? "",
                            "account_id": r.accountId, "active": r.active]
    if r.mode == .composite { d["variable_amount"] = euros(r.variableCents) }
    if let t = r.toAccountId { d["to_account"] = accountsById[t]?.name ?? ""; d["to_account_id"] = t }
    if let c = r.categoryId { d["category"] = categoriesById[c]?.name ?? "" }
    if let e = r.endDate { d["end_date"] = e }
    if !r.payee.isEmpty { d["payee"] = r.payee }
    if !r.note.isEmpty { d["note"] = r.note }
    if let next = store.expected(to: Day.adding(days: 400, to: Day.today)).first(where: { $0.recurring.id == r.id }) { d["next_due"] = next.dueDate }
    return d
}

func expectedJSON(_ e: Expected) -> [String: Any] {
    var d: [String: Any] = ["recurring_id": e.recurring.id, "name": e.recurring.name, "due_date": e.dueDate, "amount": euros(e.amountCents),
                            "flow": e.recurring.flow.rawValue, "mode": e.recurring.mode.rawValue, "account": accountsById[e.recurring.accountId]?.name ?? ""]
    if let t = e.recurring.toAccountId { d["to_account"] = accountsById[t]?.name ?? "" }
    if e.isLate { d["late_days"] = Day.diff(e.dueDate, Day.today) }
    return d
}

func summaryJSON(_ m: MonthSummary) -> [String: Any] {
    ["month": m.month, "income": euros(m.incomeCents), "expenses": euros(m.expenseCents), "net": euros(m.netCents),
     "still_expected_income": euros(m.expectedIncomeCents), "still_expected_expenses": euros(m.expectedExpenseCents),
     "by_category": m.byCategory.map { ["category": $0.categoryId.flatMap { categoriesById[$0]?.name } ?? "Bez kategórie", "amount": euros($0.cents)] as [String: Any] }]
}

// MARK: Resolving

func resolveWallet(_ v: Any?) throws -> Wallet? {
    guard let v else { return nil }
    let all = store.wallets(includeArchived: true)
    if let id = int64(v), let w = all.first(where: { $0.id == id }) { return w }
    guard let s = v as? String, !s.isEmpty else { return nil }
    let k = fold(s)
    if ["osobne", "personal", "ja", "osobna"].contains(k) { return all.first { $0.kind == .personal } }
    let hits = all.filter { fold($0.name).contains(k) }
    if hits.count == 1 { return hits[0] }
    throw ToolError(hits.isEmpty ? "Peňaženka „\(s)“ neexistuje. Peňaženky: \(all.map(\.name).joined(separator: ", "))."
                                 : "Viac peňaženiek pasuje na „\(s)“: \(hits.map(\.name).joined(separator: ", ")).")
}

/// By id, by name ("Tatra"), or "wallet / name" ("10T / Bežný účet"); a wallet alone works when it has one account.
func resolveAccount(_ v: Any?, label: String = "account") throws -> Account {
    let all = store.accounts()
    if let id = int64(v), let a = all.first(where: { $0.id == id }) { return a }
    let ws = walletsById
    func full(_ a: Account) -> String { "\(ws[a.walletId]?.name ?? "") / \(a.name)" }
    guard let s = v as? String, !s.isEmpty else {
        if all.count == 1 { return all[0] }
        throw ToolError("Chýba \(label). Účty: \(all.map(full).joined(separator: ", ")).")
    }
    let k = fold(s)
    var hits = all.filter { fold($0.name) == k || fold(full($0)) == k }
    if hits.isEmpty { hits = all.filter { fold($0.name).contains(k) || fold(full($0)).contains(k) || (!$0.iban.isEmpty && fold($0.iban).contains(k.replacingOccurrences(of: " ", with: ""))) } }
    if hits.isEmpty, let w = try? resolveWallet(s) { hits = all.filter { $0.walletId == w.id } }
    if hits.count == 1 { return hits[0] }
    throw ToolError(hits.isEmpty ? "Účet „\(s)“ neexistuje. Účty: \(all.map(full).joined(separator: ", "))."
                                 : "Viac účtov pasuje na „\(s)“: \(hits.map(full).joined(separator: ", ")).")
}

func resolveCategory(_ v: Any?, flow: Flow?) throws -> Int64? {
    guard let v else { return nil }
    if let id = int64(v), store.category(id) != nil { return id }
    guard let s = v as? String, !s.isEmpty else { return nil }
    if let c = store.category(named: s, flow: flow) { return c.id }
    let names = store.categories().filter { flow == nil || $0.flow == flow }.map(\.name)
    throw ToolError("Kategória „\(s)“ neexistuje. Kategórie: \(names.joined(separator: ", ")). Novú založíš cez category_upsert.")
}

func scope(_ a: [String: Any]) throws -> Scope {
    if a["account"] != nil { return Scope(accountId: try resolveAccount(a["account"]).id) }
    if let w = try resolveWallet(a["wallet"]) { return Scope(walletId: w.id) }
    return .all
}

func date(_ a: [String: Any], _ k: String) throws -> String? {
    guard let s = str(a, k) else { return nil }
    let low = fold(s)
    if low == "dnes" || low == "today" { return Day.today }
    if low == "vcera" || low == "yesterday" { return Day.adding(days: -1, to: Day.today) }
    guard Day.valid(s) else { throw ToolError("\(k) musí byť RRRR-MM-DD.") }
    return s
}

// MARK: Tools

let money = ["type": "number", "description": "Suma v eurách (kladná)"] as [String: Any]
let accountArg = ["type": "string", "description": "Účet: id, názov alebo „peňaženka / účet“"] as [String: Any]
let walletArg = ["type": "string", "description": "Peňaženka: id, „osobné“ alebo názov firmy"] as [String: Any]

let toolDefs: [[String: Any]] = [
    ["name": "overview", "description": "Prehľad financií: čistý majetok (osobné, firmy, spolu), zostatky účtov, tento mesiac (príjmy, výdavky, čo ešte príde), čo čaká na potvrdenie a čo príde v najbližších 14 dňoch, prognóza na 3 mesiace.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "accounts", "description": "Peňaženky (osobné, firmy) a ich účty so zostatkami.",
     "inputSchema": ["type": "object", "properties": ["include_archived": ["type": "boolean"]]]],
    ["name": "categories", "description": "Kategórie príjmov a výdavkov.", "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "transactions", "description": "Pohyby, najnovšie prvé. Filtre: wallet, account, category, kind (income, expense, transfer, adjustment), from, to (RRRR-MM-DD), query (obchodník, poznámka, kategória).",
     "inputSchema": ["type": "object", "properties": ["wallet": walletArg, "account": accountArg, "category": ["type": "string"], "kind": ["type": "string"],
                                                      "from": ["type": "string"], "to": ["type": "string"], "query": ["type": "string"], "limit": ["type": "integer"]]]],
    ["name": "transaction_add", "description": "Zapíše príjem alebo výdavok (napr. „45 € za večeru kartou“). kind: expense (predvolené) alebo income. date predvolene dnes. Kategória podľa názvu (categories).",
     "inputSchema": ["type": "object", "properties": ["account": accountArg, "amount": money, "kind": ["type": "string", "enum": ["expense", "income"]],
                                                      "date": ["type": "string"], "category": ["type": "string"], "payee": ["type": "string", "description": "Komu / od koho"],
                                                      "note": ["type": "string"]], "required": ["amount"]]],
    ["name": "transaction_update", "description": "Upraví pohyb (len zadané polia). Pri prevode sa zmení aj druhá strana.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "account": accountArg, "amount": money, "date": ["type": "string"],
                                                      "category": ["type": "string"], "payee": ["type": "string"], "note": ["type": "string"]], "required": ["id"]]],
    ["name": "transaction_delete", "description": "Zmaže pohyb (pri prevode obe strany). Ak potvrdzoval pravidelnú položku, tá sa znova čaká.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "transfer", "description": "Prevod medzi mojimi účtami, aj medzi firmou a osobnými (výplata, dividenda, vklad do firmy).",
     "inputSchema": ["type": "object", "properties": ["from_account": accountArg, "to_account": accountArg, "amount": money, "date": ["type": "string"],
                                                      "note": ["type": "string"]], "required": ["from_account", "to_account", "amount"]]],
    ["name": "reconcile", "description": "Zosúladí účet so skutočným zostatkom z banky: rozdiel sa zapíše ako korekcia.",
     "inputSchema": ["type": "object", "properties": ["account": accountArg, "balance": ["type": "number", "description": "Skutočný zostatok v eurách"],
                                                      "date": ["type": "string"]], "required": ["account", "balance"]]],
    ["name": "account_upsert", "description": "Založí alebo upraví účet (bez id založí nový, predvolene v osobnej peňaženke). type: bank, savings, cash, card, investment. opening_balance k opening_date.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "wallet": walletArg, "name": ["type": "string"], "type": ["type": "string"],
                                                      "iban": ["type": "string"], "opening_balance": ["type": "number"], "opening_date": ["type": "string"],
                                                      "archived": ["type": "boolean"]]]],
    ["name": "wallet_upsert", "description": "Založí alebo upraví peňaženku (kind personal alebo business). Firmy z Faktúr sa pridávajú samy.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "name": ["type": "string"], "kind": ["type": "string"], "archived": ["type": "boolean"]]]],
    ["name": "category_upsert", "description": "Založí alebo upraví kategóriu (flow income alebo expense, symbol je SF Symbol).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "name": ["type": "string"], "flow": ["type": "string"], "symbol": ["type": "string"],
                                                      "color": ["type": "string"], "archived": ["type": "boolean"]]]],
    ["name": "recurring_list", "description": "Pravidelné príjmy, výdavky a prevody (plán) s mesačným ekvivalentom a ďalším termínom, plus súčet plánu za mesiac.",
     "inputSchema": ["type": "object", "properties": ["wallet": walletArg]]],
    ["name": "recurring_upsert", "description": "Založí alebo upraví pravidelnú položku. flow: income, expense, transfer (s to_account). mode: fixed (vždy rovnaká suma), variable (amount je odhad), composite (amount = fixná časť, variable_amount = obvyklá pohyblivá časť, napr. plat s bonusom), irregular (raz alebo občas, frequency once/yearly). frequency: weekly, monthly, quarterly, yearly, once; interval = každý n-tý; day = deň v mesiaci (31 = posledný); start_date, end_date.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "name": ["type": "string"], "flow": ["type": "string"], "mode": ["type": "string"],
                                                      "amount": money, "variable_amount": money, "frequency": ["type": "string"], "interval": ["type": "integer"],
                                                      "day": ["type": "integer"], "start_date": ["type": "string"], "end_date": ["type": "string"],
                                                      "account": accountArg, "to_account": accountArg, "category": ["type": "string"], "payee": ["type": "string"],
                                                      "note": ["type": "string"], "active": ["type": "boolean"]]]],
    ["name": "recurring_delete", "description": "Zmaže pravidelnú položku (pohyby, ktoré už vznikli, zostanú).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "expected", "description": "Čo ešte má prísť a odísť podľa pravidelných položiek (aj omeškané, nepotvrdené). Predvolene do konca budúceho mesiaca.",
     "inputSchema": ["type": "object", "properties": ["to": ["type": "string"], "wallet": walletArg]]],
    ["name": "expected_confirm", "description": "Potvrdí očakávanú položku: vznikne skutočný pohyb. amount a date len ak sú iné ako plán (napr. skutočná faktúra za elektrinu, plat s bonusom).",
     "inputSchema": ["type": "object", "properties": ["recurring_id": ["type": "integer"], "due_date": ["type": "string"], "amount": money, "date": ["type": "string"],
                                                      "account": accountArg], "required": ["recurring_id", "due_date"]]],
    ["name": "expected_skip", "description": "Očakávaná položka tentoraz nepríde (napr. mesiac bez bonusu).",
     "inputSchema": ["type": "object", "properties": ["recurring_id": ["type": "integer"], "due_date": ["type": "string"]], "required": ["recurring_id", "due_date"]]],
    ["name": "month_summary", "description": "Mesiac: príjmy, výdavky, podľa kategórií, čo ešte príde. month RRRR-MM (predvolene tento), wallet alebo account.",
     "inputSchema": ["type": "object", "properties": ["month": ["type": "string"], "wallet": walletArg, "account": accountArg]]],
    ["name": "forecast", "description": "Prognóza zostatku na konci každého z nasledujúcich mesiacov (pravidelné položky, pohyby zadané dopredu) a história za posledné mesiace.",
     "inputSchema": ["type": "object", "properties": ["months": ["type": "integer"], "history_months": ["type": "integer"], "wallet": walletArg, "account": accountArg]]],
]
let readOnly: Set<String> = ["overview", "accounts", "categories", "transactions", "recurring_list", "expected", "month_summary", "forecast"]
let tools: [[String: Any]] = toolDefs.map { t in
    var t = t
    if readOnly.contains(t["name"] as! String) { t["annotations"] = ["readOnlyHint": true] }
    return t
}

func balances(_ wallets: [Wallet], _ kind: WalletKind) -> Int {
    wallets.filter { $0.kind == kind }.reduce(0) { $0 + store.balance(Scope(walletId: $1.id)) }
}

func call(_ name: String, _ a: [String: Any]) throws -> Any {
    switch name {
    case "overview":
        let ws = store.wallets()
        let personal = balances(ws, .personal), business = balances(ws, .business)
        let soon = store.expected(to: Day.adding(days: 14, to: Day.today))
        let accs = store.accounts()
        return ["today": Day.today, "net_worth": euros(personal + business), "personal": euros(personal), "business": euros(business),
                "wallets": ws.map { w -> [String: Any] in
                    var d = walletJSON(w)
                    d["accounts"] = accs.filter { $0.walletId == w.id }.map { ["id": $0.id, "name": $0.name, "balance": euros(store.balance($0.id))] as [String: Any] }
                    return d
                },
                "this_month": summaryJSON(store.monthSummary()),
                "waiting_confirmation": soon.filter(\.isLate).map(expectedJSON),
                "next_14_days": soon.filter { !$0.isLate }.map(expectedJSON),
                "forecast": store.forecast(months: 3).map { ["month": $0.month, "balance": euros($0.cents)] as [String: Any] },
                "last_backup": Backup.last(store) ?? NSNull()]
    case "accounts":
        let inc = a["include_archived"] as? Bool ?? false
        let accs = store.accounts(includeArchived: inc)
        return store.wallets(includeArchived: inc).map { w -> [String: Any] in
            var d = walletJSON(w)
            d["accounts"] = accs.filter { $0.walletId == w.id }.map(accountJSON)
            return d
        }
    case "categories":
        return store.categories().map { ["id": $0.id, "name": $0.name, "flow": $0.flow.rawValue, "symbol": $0.symbol] as [String: Any] }
    case "transactions":
        var f = Store.Filter(from: try date(a, "from"), to: try date(a, "to"), query: str(a, "query"), limit: (a["limit"] as? NSNumber)?.intValue ?? 50)
        if a["account"] != nil { f.accountIds = [try resolveAccount(a["account"]).id] }
        if let w = try resolveWallet(a["wallet"]) { f.walletId = w.id }
        if a["category"] != nil { f.categoryId = try resolveCategory(a["category"], flow: nil) }
        if let k = str(a, "kind") { guard let kind = TxKind(rawValue: k) else { throw ToolError("kind: income, expense, transfer, adjustment.") }; f.kinds = [kind] }
        return store.transactions(f).map(txJSON)
    case "transaction_add":
        guard let c = cents(a["amount"]), c != 0 else { throw ToolError("Chýba suma (amount v eurách).") }
        let kind: TxKind = str(a, "kind") == "income" ? .income : .expense
        let acc = try resolveAccount(a["account"])
        var t = Tx(accountId: acc.id, date: try date(a, "date") ?? Day.today, amountCents: c, kind: kind,
                            categoryId: try resolveCategory(a["category"], flow: kind == .income ? .income : .expense),
                            payee: str(a, "payee") ?? "", note: str(a, "note") ?? "")
        t.source = "mcp"
        let saved = try store.addTransaction(t)
        var d = txJSON(saved)
        d["account_balance"] = euros(store.balance(acc.id))
        return d
    case "transaction_update":
        guard let id = int64(a["id"]), var t = store.transaction(id) else { throw ToolError("Pohyb nenájdený (id).") }
        if a["account"] != nil { t.accountId = try resolveAccount(a["account"]).id }
        if let c = cents(a["amount"]) { t.amountCents = t.amountCents < 0 ? -abs(c) : abs(c) }
        if let d = try date(a, "date") { t.date = d }
        if a["category"] != nil { t.categoryId = try resolveCategory(a["category"], flow: t.kind == .income ? .income : t.kind == .expense ? .expense : nil) }
        if let s = a["payee"] as? String { t.payee = s }
        if let s = a["note"] as? String { t.note = s }
        return txJSON(try store.updateTransaction(t))
    case "transaction_delete":
        guard let id = int64(a["id"]) else { throw ToolError("Chýba id.") }
        try store.deleteTransaction(id)
        return ["deleted": true, "id": id]
    case "transfer":
        guard let c = cents(a["amount"]), c != 0 else { throw ToolError("Chýba suma (amount v eurách).") }
        let from = try resolveAccount(a["from_account"], label: "from_account"), to = try resolveAccount(a["to_account"], label: "to_account")
        let pair = try store.transfer(from: from.id, to: to.id, cents: c, date: try date(a, "date") ?? Day.today, note: str(a, "note") ?? "", source: "mcp")
        return ["transactions": pair.map(txJSON), "from_balance": euros(store.balance(from.id)), "to_balance": euros(store.balance(to.id))]
    case "reconcile":
        let acc = try resolveAccount(a["account"])
        guard let c = cents(a["balance"]) else { throw ToolError("Chýba balance (skutočný zostatok v eurách).") }
        let day = try date(a, "date") ?? Day.today
        let before = store.balance(acc.id, through: day)
        let t = try store.reconcile(accountId: acc.id, balanceCents: c, date: day)
        return ["account": acc.name, "was": euros(before), "now": euros(store.balance(acc.id)), "correction": t.map { euros($0.amountCents) } ?? 0]
    case "account_upsert":
        var acc = Account()
        if let id = int64(a["id"]) {
            guard let x = store.account(id) else { throw ToolError("Účet \(id) neexistuje.") }
            acc = x
            if a["wallet"] != nil, let w = try resolveWallet(a["wallet"]) { acc.walletId = w.id }
        } else {
            acc.walletId = (try resolveWallet(a["wallet"] ?? "osobne"))?.id ?? 0
        }
        if let s = str(a, "name") { acc.name = s }
        if let s = str(a, "type") { guard let t = AccountType(rawValue: s) else { throw ToolError("type: bank, savings, cash, card, investment.") }; acc.type = t }
        if let s = a["iban"] as? String { acc.iban = s }
        if let c = cents(a["opening_balance"]) { acc.openingCents = c }
        if let d = try date(a, "opening_date") { acc.openingDate = d }
        if let b = a["archived"] as? Bool { acc.archived = b }
        return accountJSON(try store.saveAccount(acc))
    case "wallet_upsert":
        var w = Wallet()
        if let id = int64(a["id"]) { guard let x = store.wallet(id) else { throw ToolError("Peňaženka \(id) neexistuje.") }; w = x }
        if let s = str(a, "name") { w.name = s }
        if let s = str(a, "kind") { guard let k = WalletKind(rawValue: s) else { throw ToolError("kind: personal alebo business.") }; w.kind = k }
        if let b = a["archived"] as? Bool { w.archived = b }
        return walletJSON(try store.saveWallet(w))
    case "category_upsert":
        var c = TxCategory()
        if let id = int64(a["id"]) { guard let x = store.category(id) else { throw ToolError("Kategória \(id) neexistuje.") }; c = x }
        if let s = str(a, "name") { c.name = s }
        if let s = str(a, "flow") { guard let f = Flow(rawValue: s), f != .transfer else { throw ToolError("flow: income alebo expense.") }; c.flow = f }
        if let s = str(a, "symbol") { c.symbol = s }
        if let s = str(a, "color") { c.color = s }
        if let b = a["archived"] as? Bool { c.archived = b }
        let saved = try store.saveCategory(c)
        return ["id": saved.id, "name": saved.name, "flow": saved.flow.rawValue]
    case "recurring_list":
        let w = try resolveWallet(a["wallet"])
        let ids = Set(store.accounts(includeArchived: true).filter { w == nil || $0.walletId == w!.id }.map(\.id))
        let items = store.recurringItems().filter { w == nil || ids.contains($0.accountId) || ($0.toAccountId.map(ids.contains) ?? false) }
        let plan = store.plannedMonthly(scope: Scope(walletId: w?.id))
        return ["items": items.map(recurringJSON), "monthly_income": euros(plan.income), "monthly_expenses": euros(plan.expense)]
    case "recurring_upsert":
        var r = Recurring()
        if let id = int64(a["id"]) { guard let x = store.recurringItem(id) else { throw ToolError("Položka \(id) neexistuje.") }; r = x }
        if let s = str(a, "name") { r.name = s }
        if let s = str(a, "flow") { guard let f = Flow(rawValue: s) else { throw ToolError("flow: income, expense, transfer.") }; r.flow = f }
        if let s = str(a, "mode") { guard let m = RecurringMode(rawValue: s) else { throw ToolError("mode: fixed, variable, composite, irregular.") }; r.mode = m }
        if let c = cents(a["amount"]) { r.amountCents = abs(c) }
        if let c = cents(a["variable_amount"]) { r.variableCents = abs(c); if a["mode"] == nil, r.id == 0 { r.mode = .composite } }
        if let s = str(a, "frequency") { guard let f = Frequency(rawValue: s) else { throw ToolError("frequency: weekly, monthly, quarterly, yearly, once.") }; r.frequency = f }
        if let n = (a["interval"] as? NSNumber)?.intValue { r.interval = n }
        if let n = (a["day"] as? NSNumber)?.intValue { r.day = n }
        if let d = try date(a, "start_date") { r.startDate = d; if a["day"] == nil, r.id == 0 { r.day = Int(d.suffix(2)) ?? 1 } }
        if a["end_date"] != nil { r.endDate = try date(a, "end_date") }
        if a["account"] != nil || r.id == 0 { r.accountId = try resolveAccount(a["account"]).id }
        if a["to_account"] != nil { r.toAccountId = try resolveAccount(a["to_account"], label: "to_account").id }
        if a["category"] != nil { r.categoryId = try resolveCategory(a["category"], flow: r.flow == .transfer ? nil : r.flow) }
        if let s = a["payee"] as? String { r.payee = s }
        if let s = a["note"] as? String { r.note = s }
        if let b = a["active"] as? Bool { r.active = b }
        return recurringJSON(try store.saveRecurring(r))
    case "recurring_delete":
        guard let id = int64(a["id"]) else { throw ToolError("Chýba id.") }
        try store.deleteRecurring(id)
        return ["deleted": true, "id": id]
    case "expected":
        let to = try date(a, "to") ?? Day.monthEnd(Day.addMonths(Day.month(Day.today), 1))
        var list = store.expected(to: to)
        if let w = try resolveWallet(a["wallet"]) {
            let ids = Set(store.accounts(includeArchived: true).filter { $0.walletId == w.id }.map(\.id))
            list = list.filter { ids.contains($0.recurring.accountId) || ($0.recurring.toAccountId.map(ids.contains) ?? false) }
        }
        return list.map(expectedJSON)
    case "expected_confirm":
        guard let id = int64(a["recurring_id"]), let due = try date(a, "due_date") else { throw ToolError("Chýba recurring_id a due_date.") }
        let acc = a["account"] != nil ? try resolveAccount(a["account"]).id : nil
        return ["transactions": try store.confirm(recurringId: id, dueDate: due, amountCents: cents(a["amount"]), date: try date(a, "date"), accountId: acc).map(txJSON)]
    case "expected_skip":
        guard let id = int64(a["recurring_id"]), let due = try date(a, "due_date") else { throw ToolError("Chýba recurring_id a due_date.") }
        try store.skip(recurringId: id, dueDate: due)
        return ["skipped": true, "recurring_id": id, "due_date": due]
    case "month_summary":
        let month = str(a, "month") ?? Day.month(Day.today)
        guard month.count == 7 else { throw ToolError("month musí byť RRRR-MM.") }
        let s = try scope(a)
        var d = summaryJSON(store.monthSummary(month, scope: s))
        d["balance_at_end"] = euros(store.balance(s, through: min(Day.monthEnd(month), Day.today)))
        return d
    case "forecast":
        let s = try scope(a)
        return ["now": euros(store.balance(s)),
                "history": store.history(months: (a["history_months"] as? NSNumber)?.intValue ?? 6, scope: s).map { ["month": $0.month, "balance": euros($0.cents)] as [String: Any] },
                "forecast": store.forecast(months: (a["months"] as? NSNumber)?.intValue ?? 6, scope: s).map { ["month": $0.month, "balance": euros($0.cents)] as [String: Any] }]
    default:
        throw ToolError("Neznámy nástroj \(name).")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
    guard let id = msg["id"] else { continue }
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        if let c = (params["clientInfo"] as? [String: Any])?["name"] as? String { store.actor = "mcp:\(c)" }
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "financie", "version": "0.1"],
            "instructions": "Financie sú lokálna appka používateľa na osobné a firemné financie. Peňaženky: osobné a firmy (firmy sa berú z Faktúr), každá má účty. overview = rýchly prehľad (čistý majetok, mesiac, čo čaká, prognóza). Výdavok alebo príjem z vety alebo bločku: transaction_add (kategóriu vyber z categories, účet z accounts; ak nie je jasný, opýtaj sa). Medzi mojimi účtami alebo firma ↔ osobné (výplata, dividenda): transfer. Plán: recurring_upsert (fixed, variable, composite = fix + variabilná zložka, irregular), čo čaká: expected → expected_confirm so skutočnou sumou alebo expected_skip. Skutočný zostatok z banky: reconcile. Sumy sú v eurách, kladné; znamienko určuje kind.",
        ] as [String: Any]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try call(name, args)
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])) ?? Data()
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]])
        } catch {
            let text = (error as? ToolError)?.message ?? error.localizedDescription
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
