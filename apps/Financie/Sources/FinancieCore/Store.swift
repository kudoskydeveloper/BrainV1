import Foundation

/// The Financie database (`~/Library/Application Support/Financie/financie.sqlite`, WAL), shared by the app and financie-mcp.
/// Every write posts `Store.changed`, so an open app reloads when the MCP server (Brain) changes something.
public final class Store {
    public let db: DB
    public let path: String
    /// Who writes (app, mcp:<client>), for the log.
    public var actor = "app"

    public static let changed = Notification.Name("com.lockedin.financie.changed")

    public static var defaultPath: String {
        if let p = ProcessInfo.processInfo.environment["FINANCIE_DB"] { return p }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Financie")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("financie.sqlite").path
    }

    public init(path: String? = nil) throws {
        self.path = path ?? Store.defaultPath
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: self.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DB(path: self.path)
        try migrate()
        try seed()
    }

    func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS wallets(id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            faktury_company_id INTEGER UNIQUE, archived INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS accounts(id INTEGER PRIMARY KEY, wallet_id INTEGER NOT NULL REFERENCES wallets(id), name TEXT NOT NULL,
            type TEXT NOT NULL, currency TEXT NOT NULL DEFAULT 'EUR', iban TEXT NOT NULL DEFAULT '', opening_cents INTEGER NOT NULL DEFAULT 0,
            opening_date TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL, flow TEXT NOT NULL, symbol TEXT NOT NULL,
            color TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS recurring(id INTEGER PRIMARY KEY, name TEXT NOT NULL, flow TEXT NOT NULL,
            account_id INTEGER NOT NULL REFERENCES accounts(id), to_account_id INTEGER REFERENCES accounts(id), category_id INTEGER REFERENCES categories(id),
            mode TEXT NOT NULL, amount_cents INTEGER NOT NULL, variable_cents INTEGER NOT NULL DEFAULT 0, frequency TEXT NOT NULL,
            interval INTEGER NOT NULL DEFAULT 1, day INTEGER NOT NULL DEFAULT 1, start_date TEXT NOT NULL, end_date TEXT,
            payee TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS transactions(id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL REFERENCES accounts(id), date TEXT NOT NULL,
            amount_cents INTEGER NOT NULL, kind TEXT NOT NULL, category_id INTEGER REFERENCES categories(id), payee TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '', transfer_group TEXT, recurring_id INTEGER REFERENCES recurring(id) ON DELETE SET NULL, due_date TEXT,
            source TEXT NOT NULL DEFAULT 'manual', external_ref TEXT UNIQUE, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS tx_account_date ON transactions(account_id, date);
        CREATE INDEX IF NOT EXISTS tx_date ON transactions(date);
        CREATE TABLE IF NOT EXISTS occurrences(recurring_id INTEGER NOT NULL REFERENCES recurring(id) ON DELETE CASCADE, due_date TEXT NOT NULL,
            status TEXT NOT NULL, transaction_id INTEGER, PRIMARY KEY(recurring_id, due_date));
        CREATE TABLE IF NOT EXISTS log(id INTEGER PRIMARY KEY, at TEXT NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, detail TEXT);
        """)
    }

    /// A new database starts with the personal wallet and the default categories.
    func seed() throws {
        if (try db.run("SELECT COUNT(*) AS n FROM wallets").first?["n"]?.int ?? 0) == 0 {
            try db.run("INSERT INTO wallets(name, kind, sort) VALUES ('Osobné', 'personal', 0)")
        }
        if (try db.run("SELECT COUNT(*) AS n FROM categories").first?["n"]?.int ?? 0) == 0 {
            for c in TxCategory.defaults { _ = try saveCategory(c, notify: false) }
        }
    }

    // MARK: Notifications and log

    public func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(Store.changed, object: "\(getpid())", userInfo: nil, deliverImmediately: true)
    }

    func log(_ action: String, _ detail: String) {
        _ = try? db.run("INSERT INTO log(at, actor, action, detail) VALUES (?, ?, ?, ?)", [Day.now, actor, action, detail])
    }

    public func meta(_ key: String) -> String? { (try? db.run("SELECT value FROM meta WHERE key = ?", [key]).first?["value"]?.string) ?? nil }
    public func setMeta(_ key: String, _ value: String) {
        _ = try? db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }

    // MARK: Wallets

    func wallet(_ r: Row) -> Wallet {
        var w = Wallet(id: r["id"]?.int64 ?? 0, name: r["name"]?.string ?? "", kind: WalletKind(rawValue: r["kind"]?.string ?? "") ?? .personal,
                       fakturyCompanyId: r["faktury_company_id"]?.int64)
        w.archived = r["archived"]?.int == 1
        w.sort = r["sort"]?.int ?? 0
        return w
    }

    public func wallets(includeArchived: Bool = false) -> [Wallet] {
        let rows = (try? db.run("SELECT * FROM wallets \(includeArchived ? "" : "WHERE archived = 0") ORDER BY kind = 'business', sort, name COLLATE NOCASE")) ?? []
        return rows.map(wallet)
    }

    public func wallet(_ id: Int64) -> Wallet? { (try? db.run("SELECT * FROM wallets WHERE id = ?", [id]).first).flatMap { $0 }.map(wallet) }

    @discardableResult
    public func saveWallet(_ w: Wallet) throws -> Wallet {
        let name = w.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw FinancieError("Peňaženka potrebuje názov.") }
        var w = w; w.name = name
        if w.id == 0 {
            try db.run("INSERT INTO wallets(name, kind, faktury_company_id, archived, sort) VALUES (?, ?, ?, ?, ?)",
                       [w.name, w.kind.rawValue, w.fakturyCompanyId, w.archived, w.sort])
            w.id = db.lastID
        } else {
            try db.run("UPDATE wallets SET name = ?, kind = ?, faktury_company_id = ?, archived = ?, sort = ? WHERE id = ?",
                       [w.name, w.kind.rawValue, w.fakturyCompanyId, w.archived, w.sort, w.id])
        }
        log("wallet_save", "\(w.id) \(w.name)")
        notifyChanged()
        return w
    }

    // MARK: Accounts

    func account(_ r: Row) -> Account {
        var a = Account(id: r["id"]?.int64 ?? 0, walletId: r["wallet_id"]?.int64 ?? 0, name: r["name"]?.string ?? "",
                        type: AccountType(rawValue: r["type"]?.string ?? "") ?? .bank, openingCents: r["opening_cents"]?.int ?? 0,
                        openingDate: r["opening_date"]?.string ?? Day.today)
        a.currency = r["currency"]?.string ?? "EUR"
        a.iban = r["iban"]?.string ?? ""
        a.archived = r["archived"]?.int == 1
        a.sort = r["sort"]?.int ?? 0
        return a
    }

    public func accounts(includeArchived: Bool = false) -> [Account] {
        let rows = (try? db.run("SELECT * FROM accounts \(includeArchived ? "" : "WHERE archived = 0") ORDER BY wallet_id, sort, name COLLATE NOCASE")) ?? []
        return rows.map(account)
    }

    public func account(_ id: Int64) -> Account? { (try? db.run("SELECT * FROM accounts WHERE id = ?", [id]).first).flatMap { $0 }.map(account) }

    @discardableResult
    public func saveAccount(_ a: Account) throws -> Account {
        var a = a
        a.name = a.name.trimmingCharacters(in: .whitespaces)
        a.iban = a.iban.replacingOccurrences(of: " ", with: "").uppercased()
        guard !a.name.isEmpty else { throw FinancieError("Účet potrebuje názov.") }
        guard wallet(a.walletId) != nil else { throw FinancieError("Peňaženka účtu neexistuje.") }
        guard Day.valid(a.openingDate) else { throw FinancieError("Dátum počiatočného zostatku musí byť RRRR-MM-DD.") }
        if a.id == 0 {
            try db.run("INSERT INTO accounts(wallet_id, name, type, currency, iban, opening_cents, opening_date, archived, sort) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [a.walletId, a.name, a.type.rawValue, a.currency, a.iban, a.openingCents, a.openingDate, a.archived, a.sort])
            a.id = db.lastID
        } else {
            try db.run("UPDATE accounts SET wallet_id = ?, name = ?, type = ?, currency = ?, iban = ?, opening_cents = ?, opening_date = ?, archived = ?, sort = ? WHERE id = ?",
                       [a.walletId, a.name, a.type.rawValue, a.currency, a.iban, a.openingCents, a.openingDate, a.archived, a.sort, a.id])
        }
        log("account_save", "\(a.id) \(a.name)")
        notifyChanged()
        return a
    }

    /// An account with transactions can only be archived (its history stays in the reports).
    public func deleteAccount(_ id: Int64) throws {
        let n = try db.run("SELECT COUNT(*) AS n FROM transactions WHERE account_id = ?", [id]).first?["n"]?.int ?? 0
        let r = try db.run("SELECT COUNT(*) AS n FROM recurring WHERE account_id = ? OR to_account_id = ?", [id, id]).first?["n"]?.int ?? 0
        guard n == 0, r == 0 else { throw FinancieError("Účet má pohyby alebo pravidelné položky, dá sa len archivovať.") }
        try db.run("DELETE FROM accounts WHERE id = ?", [id])
        log("account_delete", "\(id)")
        notifyChanged()
    }

    // MARK: Categories

    func category(_ r: Row) -> TxCategory {
        var c = TxCategory(id: r["id"]?.int64 ?? 0, name: r["name"]?.string ?? "", flow: Flow(rawValue: r["flow"]?.string ?? "") ?? .expense,
                         symbol: r["symbol"]?.string ?? "circle.fill", color: r["color"]?.string ?? "gray")
        c.archived = r["archived"]?.int == 1
        return c
    }

    public func categories(includeArchived: Bool = false) -> [TxCategory] {
        let rows = (try? db.run("SELECT * FROM categories \(includeArchived ? "" : "WHERE archived = 0") ORDER BY flow = 'expense', id")) ?? []
        return rows.map(category)
    }

    public func category(_ id: Int64) -> TxCategory? { (try? db.run("SELECT * FROM categories WHERE id = ?", [id]).first).flatMap { $0 }.map(category) }

    /// By name, ignoring case and diacritics ("restauracie" finds Reštaurácie).
    public func category(named name: String, flow: Flow? = nil) -> TxCategory? {
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        let all = categories(includeArchived: true).filter { flow == nil || $0.flow == flow }
        func f(_ c: TxCategory) -> String { c.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return all.first { f($0) == key } ?? all.first { f($0).hasPrefix(key) } ?? all.first { f($0).contains(key) }
    }

    @discardableResult
    public func saveCategory(_ c: TxCategory, notify: Bool = true) throws -> TxCategory {
        var c = c
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty else { throw FinancieError("Kategória potrebuje názov.") }
        guard c.flow != .transfer else { throw FinancieError("Kategória je pre príjem alebo výdavok.") }
        if c.id == 0 {
            try db.run("INSERT INTO categories(name, flow, symbol, color, archived) VALUES (?, ?, ?, ?, ?)", [c.name, c.flow.rawValue, c.symbol, c.color, c.archived])
            c.id = db.lastID
        } else {
            try db.run("UPDATE categories SET name = ?, flow = ?, symbol = ?, color = ?, archived = ? WHERE id = ?", [c.name, c.flow.rawValue, c.symbol, c.color, c.archived, c.id])
        }
        if notify { log("category_save", "\(c.id) \(c.name)"); notifyChanged() }
        return c
    }

    // MARK: Transactions

    func transaction(_ r: Row) -> Tx {
        var t = Tx(id: r["id"]?.int64 ?? 0, accountId: r["account_id"]?.int64 ?? 0, date: r["date"]?.string ?? "", amountCents: r["amount_cents"]?.int ?? 0,
                            kind: TxKind(rawValue: r["kind"]?.string ?? "") ?? .expense, categoryId: r["category_id"]?.int64,
                            payee: r["payee"]?.string ?? "", note: r["note"]?.string ?? "")
        t.transferGroup = r["transfer_group"]?.string
        t.recurringId = r["recurring_id"]?.int64
        t.dueDate = r["due_date"]?.string
        t.source = r["source"]?.string ?? "manual"
        return t
    }

    public struct Filter {
        public var accountIds: [Int64]?
        public var walletId: Int64?
        public var categoryId: Int64?
        public var kinds: [TxKind]?
        public var from: String?
        public var to: String?
        public var query: String?
        public var limit: Int?
        public init(accountIds: [Int64]? = nil, walletId: Int64? = nil, categoryId: Int64? = nil, kinds: [TxKind]? = nil, from: String? = nil,
                    to: String? = nil, query: String? = nil, limit: Int? = nil) {
            self.accountIds = accountIds; self.walletId = walletId; self.categoryId = categoryId; self.kinds = kinds
            self.from = from; self.to = to; self.query = query; self.limit = limit
        }
    }

    /// Newest first.
    public func transactions(_ f: Filter = Filter()) -> [Tx] {
        var sql = "SELECT t.* FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE 1"
        var args: [Any?] = []
        if let ids = f.accountIds { sql += " AND t.account_id IN (\(ids.map { String($0) }.joined(separator: ",").isEmpty ? "0" : ids.map { String($0) }.joined(separator: ",")))" }
        if let w = f.walletId { sql += " AND a.wallet_id = ?"; args.append(w) }
        if let c = f.categoryId { sql += " AND t.category_id = ?"; args.append(c) }
        if let k = f.kinds, !k.isEmpty { sql += " AND t.kind IN (\(k.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        if let d = f.from { sql += " AND t.date >= ?"; args.append(d) }
        if let d = f.to { sql += " AND t.date <= ?"; args.append(d) }
        sql += " ORDER BY t.date DESC, t.id DESC"
        var rows = ((try? db.run(sql, args)) ?? []).map(transaction)
        if let q = f.query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let cats = Dictionary(uniqueKeysWithValues: categories(includeArchived: true).map { ($0.id, $0.name) })
            func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            let k = fold(q)
            rows = rows.filter { t in
                [t.payee, t.note, t.categoryId.flatMap { cats[$0] } ?? "", Money.string(abs(t.amountCents))].contains { fold($0).contains(k) }
            }
        }
        if let l = f.limit { rows = Array(rows.prefix(l)) }
        return rows
    }

    public func transaction(_ id: Int64) -> Tx? { (try? db.run("SELECT * FROM transactions WHERE id = ?", [id]).first).flatMap { $0 }.map(transaction) }

    /// The sign follows the kind: an expense is stored negative, an income positive (whatever sign the amount came with).
    func normalized(_ t: Tx) throws -> Tx {
        var t = t
        t.payee = t.payee.trimmingCharacters(in: .whitespaces)
        t.note = t.note.trimmingCharacters(in: .whitespaces)
        guard account(t.accountId) != nil else { throw FinancieError("Účet neexistuje.") }
        guard Day.valid(t.date) else { throw FinancieError("Dátum musí byť RRRR-MM-DD.") }
        guard t.amountCents != 0 || t.kind == .adjustment else { throw FinancieError("Suma nemôže byť nula.") }
        switch t.kind {
        case .income: t.amountCents = abs(t.amountCents)
        case .expense: t.amountCents = -abs(t.amountCents)
        case .transfer, .adjustment: break
        }
        if let c = t.categoryId {
            guard let cat = category(c) else { throw FinancieError("Kategória neexistuje.") }
            if t.kind == .income && cat.flow != .income { throw FinancieError("„\(cat.name)“ je kategória výdavkov, nie príjmov.") }
            if t.kind == .expense && cat.flow != .expense { throw FinancieError("„\(cat.name)“ je kategória príjmov, nie výdavkov.") }
        }
        return t
    }

    func insert(_ t: Tx, externalRef: String? = nil) throws -> Tx {
        var t = t
        try db.run("""
            INSERT INTO transactions(account_id, date, amount_cents, kind, category_id, payee, note, transfer_group, recurring_id, due_date, source, external_ref, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [t.accountId, t.date, t.amountCents, t.kind.rawValue, t.categoryId, t.payee, t.note, t.transferGroup, t.recurringId, t.dueDate, t.source,
                  externalRef, Day.now, Day.now])
        t.id = db.lastID
        return t
    }

    @discardableResult
    public func addTransaction(_ t: Tx) throws -> Tx {
        guard t.kind != .transfer else { throw FinancieError("Prevod sa zapisuje cez transfer (dva účty).") }
        let saved = try db.transaction { try insert(try normalized(t)) }
        log("tx_add", "\(saved.id) \(saved.amountCents) \(saved.payee)")
        notifyChanged()
        return saved
    }

    /// Changes a transaction; a transfer keeps both halves in step (amount and date).
    @discardableResult
    public func updateTransaction(_ t: Tx) throws -> Tx {
        guard let old = transaction(t.id) else { throw FinancieError("Pohyb neexistuje.") }
        var t = t
        if old.kind == .transfer { t.kind = .transfer } else if t.kind == .transfer { throw FinancieError("Pohyb sa nedá zmeniť na prevod.") }
        let n = try normalized(t)
        try db.transaction {
            try db.run("UPDATE transactions SET account_id = ?, date = ?, amount_cents = ?, kind = ?, category_id = ?, payee = ?, note = ?, updated_at = ? WHERE id = ?",
                       [n.accountId, n.date, n.amountCents, n.kind.rawValue, n.categoryId, n.payee, n.note, Day.now, n.id])
            if let g = old.transferGroup {
                try db.run("UPDATE transactions SET date = ?, amount_cents = ?, note = ?, updated_at = ? WHERE transfer_group = ? AND id <> ?",
                           [n.date, -n.amountCents, n.note, Day.now, g, n.id])
            }
        }
        log("tx_update", "\(n.id)")
        notifyChanged()
        return transaction(n.id)!
    }

    /// Deletes a transaction (both halves of a transfer); an occurrence it confirmed is expected again.
    public func deleteTransaction(_ id: Int64) throws {
        guard let t = transaction(id) else { throw FinancieError("Pohyb neexistuje.") }
        try db.transaction {
            let ids = t.transferGroup.map { g in ((try? db.run("SELECT id FROM transactions WHERE transfer_group = ?", [g])) ?? []).compactMap { $0["id"]?.int64 } } ?? [id]
            for i in ids {
                try db.run("DELETE FROM occurrences WHERE transaction_id = ?", [i])
                try db.run("DELETE FROM transactions WHERE id = ?", [i])
            }
        }
        log("tx_delete", "\(id)")
        notifyChanged()
    }

    /// Money from one of my accounts to another (also between wallets: salary or a dividend from my company, a deposit into it).
    @discardableResult
    public func transfer(from: Int64, to: Int64, cents: Int, date: String = Day.today, note: String = "", categoryId: Int64? = nil,
                         recurringId: Int64? = nil, dueDate: String? = nil, source: String = "manual") throws -> [Tx] {
        guard from != to else { throw FinancieError("Prevod musí ísť medzi dvoma rôznymi účtami.") }
        guard account(from) != nil, account(to) != nil else { throw FinancieError("Účet prevodu neexistuje.") }
        guard cents != 0 else { throw FinancieError("Suma nemôže byť nula.") }
        guard Day.valid(date) else { throw FinancieError("Dátum musí byť RRRR-MM-DD.") }
        let g = UUID().uuidString
        func half(_ acc: Int64, _ amount: Int) -> Tx {
            var t = Tx(accountId: acc, date: date, amountCents: amount, kind: .transfer, categoryId: categoryId, note: note)
            t.transferGroup = g; t.recurringId = recurringId; t.dueDate = dueDate; t.source = source
            return t
        }
        let out = try db.transaction { [try insert(half(from, -abs(cents))), try insert(half(to, abs(cents)))] }
        log("transfer", "\(from) → \(to) \(cents)")
        notifyChanged()
        return out
    }

    /// The other half of a transfer.
    public func counterpart(_ t: Tx) -> Tx? {
        guard let g = t.transferGroup else { return nil }
        return (try? db.run("SELECT * FROM transactions WHERE transfer_group = ? AND id <> ?", [g, t.id]).first).flatMap { $0 }.map(transaction)
    }

    /// Makes the account show the balance the bank shows: the difference becomes a correction on that day (none if it already matches).
    @discardableResult
    public func reconcile(accountId: Int64, balanceCents: Int, date: String = Day.today) throws -> Tx? {
        guard account(accountId) != nil else { throw FinancieError("Účet neexistuje.") }
        let diff = balanceCents - balance(accountId, through: date)
        guard diff != 0 else { return nil }
        var t = Tx(accountId: accountId, date: date, amountCents: diff, kind: .adjustment, note: "Zosúladenie so zostatkom \(Money.string(balanceCents))")
        t.source = actor.hasPrefix("mcp") ? "mcp" : "manual"
        return try addTransaction(t)
    }

    // MARK: Recurring

    func recurring(_ r: Row) -> Recurring {
        var x = Recurring(id: r["id"]?.int64 ?? 0, name: r["name"]?.string ?? "", flow: Flow(rawValue: r["flow"]?.string ?? "") ?? .expense,
                          accountId: r["account_id"]?.int64 ?? 0, mode: RecurringMode(rawValue: r["mode"]?.string ?? "") ?? .fixed,
                          amountCents: r["amount_cents"]?.int ?? 0, frequency: Frequency(rawValue: r["frequency"]?.string ?? "") ?? .monthly,
                          day: r["day"]?.int ?? 1, startDate: r["start_date"]?.string ?? Day.today)
        x.toAccountId = r["to_account_id"]?.int64
        x.categoryId = r["category_id"]?.int64
        x.variableCents = r["variable_cents"]?.int ?? 0
        x.interval = r["interval"]?.int ?? 1
        x.endDate = r["end_date"]?.string
        x.payee = r["payee"]?.string ?? ""
        x.note = r["note"]?.string ?? ""
        x.active = r["active"]?.int != 0
        x.createdAt = r["created_at"]?.string ?? Day.today
        return x
    }

    public func recurringItems(includeInactive: Bool = true) -> [Recurring] {
        let rows = (try? db.run("SELECT * FROM recurring \(includeInactive ? "" : "WHERE active = 1") ORDER BY flow, name COLLATE NOCASE")) ?? []
        return rows.map(recurring)
    }

    public func recurringItem(_ id: Int64) -> Recurring? { (try? db.run("SELECT * FROM recurring WHERE id = ?", [id]).first).flatMap { $0 }.map(recurring) }

    @discardableResult
    public func saveRecurring(_ r: Recurring) throws -> Recurring {
        var r = r
        r.name = r.name.trimmingCharacters(in: .whitespaces)
        r.amountCents = abs(r.amountCents)
        r.variableCents = r.mode == .composite ? abs(r.variableCents) : 0
        r.interval = max(r.interval, 1)
        r.day = min(max(r.day, 1), 31)
        guard !r.name.isEmpty else { throw FinancieError("Pravidelná položka potrebuje názov.") }
        guard account(r.accountId) != nil else { throw FinancieError("Účet položky neexistuje.") }
        guard r.amountCents > 0 || r.variableCents > 0 else { throw FinancieError("Zadaj sumu (pri variabilnej odhad).") }
        guard Day.valid(r.startDate) else { throw FinancieError("Začiatok musí byť RRRR-MM-DD.") }
        if let e = r.endDate { guard Day.valid(e), e >= r.startDate else { throw FinancieError("Koniec musí byť po začiatku (RRRR-MM-DD).") } }
        if r.flow == .transfer {
            guard let to = r.toAccountId, to != r.accountId, account(to) != nil else { throw FinancieError("Pravidelný prevod potrebuje cieľový účet.") }
        } else { r.toAccountId = nil }
        if r.mode == .irregular && r.frequency != .once && r.frequency != .yearly { r.frequency = .once }
        if let c = r.categoryId, let cat = category(c), r.flow != .transfer, cat.flow != r.flow {
            throw FinancieError("„\(cat.name)“ je kategória \(cat.flow == .income ? "príjmov" : "výdavkov").")
        }
        if r.id == 0 {
            try db.run("""
                INSERT INTO recurring(name, flow, account_id, to_account_id, category_id, mode, amount_cents, variable_cents, frequency, interval, day,
                    start_date, end_date, payee, note, active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [r.name, r.flow.rawValue, r.accountId, r.toAccountId, r.categoryId, r.mode.rawValue, r.amountCents, r.variableCents, r.frequency.rawValue,
                      r.interval, r.day, r.startDate, r.endDate, r.payee, r.note, r.active, Day.today])
            r.id = db.lastID
            r.createdAt = Day.today
        } else {
            try db.run("""
                UPDATE recurring SET name = ?, flow = ?, account_id = ?, to_account_id = ?, category_id = ?, mode = ?, amount_cents = ?, variable_cents = ?,
                    frequency = ?, interval = ?, day = ?, start_date = ?, end_date = ?, payee = ?, note = ?, active = ? WHERE id = ?
                """, [r.name, r.flow.rawValue, r.accountId, r.toAccountId, r.categoryId, r.mode.rawValue, r.amountCents, r.variableCents, r.frequency.rawValue,
                      r.interval, r.day, r.startDate, r.endDate, r.payee, r.note, r.active, r.id])
        }
        log("recurring_save", "\(r.id) \(r.name)")
        notifyChanged()
        return r
    }

    /// Deletes the plan; transactions it already produced stay (without the link).
    public func deleteRecurring(_ id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE transactions SET recurring_id = NULL WHERE recurring_id = ?", [id])
            try db.run("DELETE FROM occurrences WHERE recurring_id = ?", [id])
            try db.run("DELETE FROM recurring WHERE id = ?", [id])
        }
        log("recurring_delete", "\(id)")
        notifyChanged()
    }

    // MARK: Expected occurrences

    /// Occurrences already confirmed or skipped: "recurringId@date".
    func resolved() -> Set<String> {
        Set(((try? db.run("SELECT recurring_id, due_date FROM occurrences")) ?? []).map { "\($0["recurring_id"]?.int64 ?? 0)@\($0["due_date"]?.string ?? "")" })
    }

    /// What recurring items still expect up to `to` (and from `from`), oldest first. Late ones (not confirmed yet) go back to
    /// the item's start, at most 90 days. A new item starts today, so it has none; one started earlier by hand shows what
    /// should have come since (confirming it on a day before the account's opening balance doesn't change the balance).
    public func expected(to: String, from: String? = nil) -> [Expected] {
        let done = resolved()
        let floor = Day.adding(days: -90, to: Day.today)
        var out: [Expected] = []
        for r in recurringItems(includeInactive: false) {
            let lower = [r.startDate, floor, from ?? ""].max()!
            for d in Schedule.dates(r, from: lower, to: to) where !done.contains("\(r.id)@\(d)") {
                out.append(Expected(recurring: r, dueDate: d))
            }
        }
        return out.sorted { ($0.dueDate, $0.recurring.name) < ($1.dueDate, $1.recurring.name) }
    }

    /// Turns an expected occurrence into a real transaction (with the real amount and day, if different) and marks it done.
    @discardableResult
    public func confirm(recurringId: Int64, dueDate: String, amountCents: Int? = nil, date: String? = nil, accountId: Int64? = nil) throws -> [Tx] {
        guard let r = recurringItem(recurringId) else { throw FinancieError("Pravidelná položka neexistuje.") }
        guard !resolved().contains("\(recurringId)@\(dueDate)") else { throw FinancieError("Tento výskyt už je vybavený.") }
        let cents = abs(amountCents ?? r.expectedCents)
        let day = date ?? (dueDate > Day.today ? Day.today : dueDate)
        let acc = accountId ?? r.accountId
        let made: [Tx]
        if r.flow == .transfer {
            made = try transfer(from: acc, to: r.toAccountId ?? 0, cents: cents, date: day, note: r.name, categoryId: nil, recurringId: r.id, dueDate: dueDate,
                                source: actor.hasPrefix("mcp") ? "mcp" : "manual")
        } else {
            var t = Tx(accountId: acc, date: day, amountCents: cents, kind: r.flow == .income ? .income : .expense, categoryId: r.categoryId,
                                payee: r.payee.isEmpty ? r.name : r.payee, note: r.note)
            t.recurringId = r.id; t.dueDate = dueDate; t.source = actor.hasPrefix("mcp") ? "mcp" : "manual"
            made = [try addTransaction(t)]
        }
        try db.run("INSERT INTO occurrences(recurring_id, due_date, status, transaction_id) VALUES (?, ?, 'confirmed', ?)", [r.id, dueDate, made.first?.id])
        log("confirm", "\(r.id)@\(dueDate)")
        notifyChanged()
        return made
    }

    /// This time it doesn't come (a month without the bonus, a cancelled payment).
    public func skip(recurringId: Int64, dueDate: String) throws {
        guard recurringItem(recurringId) != nil else { throw FinancieError("Pravidelná položka neexistuje.") }
        try db.run("INSERT INTO occurrences(recurring_id, due_date, status) VALUES (?, ?, 'skipped') ON CONFLICT DO NOTHING", [recurringId, dueDate])
        log("skip", "\(recurringId)@\(dueDate)")
        notifyChanged()
    }
}

/// When a recurring item comes.
public enum Schedule {
    /// Its dates between from and to (both included), never before its start or after its end.
    public static func dates(_ r: Recurring, from: String, to: String) -> [String] {
        let end = [to, r.endDate ?? to].min()!
        guard r.startDate <= end else { return [] }
        var out: [String] = []
        switch r.frequency {
        case .once:
            if r.startDate >= from && r.startDate <= end { out.append(r.startDate) }
        case .weekly:
            var d = r.startDate
            let step = 7 * max(r.interval, 1)
            if d < from { let skip = Day.diff(d, from) / step; d = Day.adding(days: skip * step, to: d) }
            while d <= end { if d >= from { out.append(d) }; d = Day.adding(days: step, to: d) }
        case .monthly, .quarterly, .yearly:
            let step = (r.frequency == .monthly ? 1 : r.frequency == .quarterly ? 3 : 12) * max(r.interval, 1)
            let p = r.startDate.split(separator: "-").compactMap { Int($0) }
            var y = p[0], m = p[1]
            // jump close to `from` so a plan started years ago doesn't walk every month
            let monthsToFrom = (Int(from.prefix(4))! - y) * 12 + (Int(from.dropFirst(5).prefix(2))! - m)
            if monthsToFrom > step { let k = (monthsToFrom / step - 1) * step; m += k; y += (m - 1) / 12; m = (m - 1) % 12 + 1 }
            while true {
                let d = Day.clamped(year: y, month: m, day: r.day)
                if d > end { break }
                if d >= from && d >= r.startDate { out.append(d) }
                m += step; y += (m - 1) / 12; m = (m - 1) % 12 + 1
            }
        }
        return out
    }
}
