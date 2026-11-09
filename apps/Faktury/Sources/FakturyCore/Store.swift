import CryptoKit
import Foundation

/// All invoice data in one SQLite file, shared by the app and faktury-mcp. Issued documents are locked by triggers in the
/// database itself; every change lands in the audit log.
public final class Store {
    public static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["FAKTURY_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Faktury")
    }
    public static let changed = Notification.Name("com.lockedin.faktury.changed")

    public let db: DB
    public let dir: URL
    /// Who is writing, for the audit log: "app", "mcp", "mcp:<client>", "import".
    public var actor = "app"
    /// Post the cross-process change notification after writes (off in tests).
    public var notify = true

    public init(dir: URL = Store.dir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        db = try DB(path: dir.appendingPathComponent("faktury.sqlite").path)
        try migrate()
    }

    public var pdfDir: URL { dir.appendingPathComponent("pdf") }

    // MARK: Schema

    func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS companies(id INTEGER PRIMARY KEY, name TEXT NOT NULL, data TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT, updated_at TEXT);
        CREATE TABLE IF NOT EXISTS clients(id INTEGER PRIMARY KEY, name TEXT NOT NULL, ico TEXT, data TEXT NOT NULL, created_at TEXT, updated_at TEXT);
        CREATE TABLE IF NOT EXISTS number_series(company_id INTEGER NOT NULL, kind TEXT NOT NULL, year INTEGER NOT NULL, next_number INTEGER NOT NULL,
            PRIMARY KEY(company_id, kind, year));
        CREATE TABLE IF NOT EXISTS invoices(
            id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL REFERENCES companies(id), kind TEXT NOT NULL, status TEXT NOT NULL,
            number TEXT, variable_symbol TEXT, client_id INTEGER, client_snapshot TEXT NOT NULL, supplier_snapshot TEXT,
            issue_date TEXT, delivery_date TEXT, due_date TEXT, currency TEXT NOT NULL DEFAULT 'EUR', payment_method TEXT, vat_mode TEXT, vat_note TEXT,
            credits_invoice_id INTEGER, credit_reason TEXT, proforma_id INTEGER, note TEXT, internal_note TEXT,
            subtotal_cents INTEGER NOT NULL DEFAULT 0, vat_cents INTEGER NOT NULL DEFAULT 0, total_cents INTEGER NOT NULL DEFAULT 0,
            pdf_path TEXT, pdf_sha256 TEXT, sent_at TEXT, sent_via TEXT, paid_cents INTEGER NOT NULL DEFAULT 0, paid_at TEXT,
            einvoice INTEGER NOT NULL DEFAULT 0, created_at TEXT, updated_at TEXT, issued_at TEXT,
            UNIQUE(company_id, kind, number));
        CREATE TABLE IF NOT EXISTS invoice_items(id INTEGER PRIMARY KEY, invoice_id INTEGER NOT NULL REFERENCES invoices(id), position INTEGER NOT NULL,
            uuid TEXT, description TEXT NOT NULL, quantity REAL NOT NULL, unit TEXT, unit_code TEXT, unit_price_cents INTEGER NOT NULL,
            vat_rate REAL NOT NULL, line_net_cents INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS items_by_invoice ON invoice_items(invoice_id);
        CREATE TABLE IF NOT EXISTS payments(id INTEGER PRIMARY KEY, invoice_id INTEGER NOT NULL REFERENCES invoices(id), date TEXT NOT NULL,
            amount_cents INTEGER NOT NULL, method TEXT, source TEXT, note TEXT, created_at TEXT);
        CREATE TABLE IF NOT EXISTS audit_log(id INTEGER PRIMARY KEY, at TEXT NOT NULL, actor TEXT NOT NULL, entity TEXT NOT NULL, entity_id INTEGER,
            action TEXT NOT NULL, before TEXT, after TEXT);

        """)
        // v2: documents imported from earlier invoicing (their original PDF, not rendered here)
        let cols = try db.run("PRAGMA table_info(invoices)").compactMap { $0["name"]?.string }
        if !cols.contains("imported") { try db.exec("ALTER TABLE invoices ADD COLUMN imported INTEGER NOT NULL DEFAULT 0") }
        try db.exec("""
        -- An issued document never changes: only notes, sending and payment state may. (Recreated on every start, so it follows the schema.)
        DROP TRIGGER IF EXISTS invoices_locked;
        CREATE TRIGGER invoices_locked BEFORE UPDATE ON invoices WHEN OLD.status <> 'draft' AND (
            NEW.status = 'draft' OR NEW.number IS NOT OLD.number OR NEW.company_id IS NOT OLD.company_id OR NEW.kind IS NOT OLD.kind
            OR NEW.variable_symbol IS NOT OLD.variable_symbol OR NEW.client_id IS NOT OLD.client_id OR NEW.client_snapshot IS NOT OLD.client_snapshot
            OR NEW.supplier_snapshot IS NOT OLD.supplier_snapshot OR NEW.issue_date IS NOT OLD.issue_date OR NEW.delivery_date IS NOT OLD.delivery_date
            OR NEW.due_date IS NOT OLD.due_date OR NEW.currency IS NOT OLD.currency OR NEW.payment_method IS NOT OLD.payment_method
            OR NEW.vat_mode IS NOT OLD.vat_mode OR NEW.vat_note IS NOT OLD.vat_note OR NEW.credits_invoice_id IS NOT OLD.credits_invoice_id
            OR NEW.credit_reason IS NOT OLD.credit_reason OR NEW.note IS NOT OLD.note
            OR NEW.subtotal_cents IS NOT OLD.subtotal_cents OR NEW.vat_cents IS NOT OLD.vat_cents OR NEW.total_cents IS NOT OLD.total_cents
            OR NEW.pdf_path IS NOT OLD.pdf_path OR NEW.imported IS NOT OLD.imported OR NEW.pdf_sha256 IS NOT OLD.pdf_sha256 OR NEW.issued_at IS NOT OLD.issued_at
            OR (OLD.status = 'cancelled' AND NEW.status <> 'cancelled'))
        BEGIN SELECT RAISE(ABORT, 'FAKTURY: Vystavený doklad sa nedá meniť. Oprav ho dobropisom.'); END;
        CREATE TRIGGER IF NOT EXISTS invoices_no_delete BEFORE DELETE ON invoices WHEN OLD.status <> 'draft'
        BEGIN SELECT RAISE(ABORT, 'FAKTURY: Vystavený doklad sa nedá zmazať.'); END;
        CREATE TRIGGER IF NOT EXISTS items_locked_u BEFORE UPDATE ON invoice_items WHEN (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft'
        BEGIN SELECT RAISE(ABORT, 'FAKTURY: Položky vystaveného dokladu sa nedajú meniť.'); END;
        CREATE TRIGGER IF NOT EXISTS items_locked_i BEFORE INSERT ON invoice_items WHEN (SELECT status FROM invoices WHERE id = NEW.invoice_id) <> 'draft'
        BEGIN SELECT RAISE(ABORT, 'FAKTURY: Položky vystaveného dokladu sa nedajú meniť.'); END;
        CREATE TRIGGER IF NOT EXISTS items_locked_d BEFORE DELETE ON invoice_items WHEN (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft'
        BEGIN SELECT RAISE(ABORT, 'FAKTURY: Položky vystaveného dokladu sa nedajú meniť.'); END;
        CREATE TRIGGER IF NOT EXISTS audit_append_only_u BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT, 'FAKTURY: Audit log sa nedá meniť.'); END;
        CREATE TRIGGER IF NOT EXISTS audit_append_only_d BEFORE DELETE ON audit_log BEGIN SELECT RAISE(ABORT, 'FAKTURY: Audit log sa nedá meniť.'); END;
        INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', '2');
        """)
        try migrateTemplates()
    }

    // MARK: JSON

    static let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()
    static let dec = JSONDecoder()
    static func json<T: Encodable>(_ v: T) -> String { (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
    static func decode<T: Decodable>(_ t: T.Type, _ s: String?) -> T? { s.flatMap { try? dec.decode(T.self, from: Data($0.utf8)) } }

    // MARK: Audit

    func audit(_ entity: String, _ id: Int64?, _ action: String, before: String? = nil, after: String? = nil) throws {
        try db.run("INSERT INTO audit_log(at, actor, entity, entity_id, action, before, after) VALUES (?,?,?,?,?,?,?)",
                   [Day.now, actor, entity, id, action, before, after])
    }

    public struct AuditEntry: Identifiable, Hashable { public let id: Int64; public let at, actor, entity, action: String; public let entityId: Int64? }
    public func auditLog(entity: String? = nil, id: Int64? = nil, limit: Int = 200) -> [AuditEntry] {
        let rows = (try? db.run("SELECT id, at, actor, entity, entity_id, action FROM audit_log WHERE (? IS NULL OR entity = ?) AND (? IS NULL OR entity_id = ?) ORDER BY id DESC LIMIT ?",
                                [entity, entity, id, id, limit])) ?? []
        return rows.map { AuditEntry(id: $0["id"]?.int64 ?? 0, at: $0["at"]?.string ?? "", actor: $0["actor"]?.string ?? "", entity: $0["entity"]?.string ?? "",
                                     action: $0["action"]?.string ?? "", entityId: $0["entity_id"]?.int64) }
    }

    func changed() {
        guard notify else { return }
        DistributedNotificationCenter.default().postNotificationName(Store.changed, object: "\(getpid())", userInfo: nil, deliverImmediately: true)
    }

    // MARK: Companies

    public func companies(includeArchived: Bool = false) -> [Company] {
        let rows = (try? db.run("SELECT id, data FROM companies \(includeArchived ? "" : "WHERE archived = 0") ORDER BY name COLLATE NOCASE")) ?? []
        return rows.compactMap { r in
            guard var c = Store.decode(Company.self, r["data"]?.string) else { return nil }
            c.id = r["id"]?.int64 ?? 0
            return c
        }
    }

    public func company(_ id: Int64) -> Company? {
        guard let r = try? db.run("SELECT id, data FROM companies WHERE id = ?", [id]).first, var c = Store.decode(Company.self, r["data"]?.string) else { return nil }
        c.id = id
        return c
    }

    @discardableResult
    public func save(_ company: Company) throws -> Company {
        var c = company
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty else { throw FakturyError("Subjekt musí mať názov.") }
        c.iban = c.iban.replacingOccurrences(of: " ", with: "").uppercased()
        try db.transaction {
            if c.id == 0 {
                try db.run("INSERT INTO companies(name, data, archived, created_at, updated_at) VALUES (?,?,?,?,?)", [c.name, "{}", c.archived, Day.now, Day.now])
                c.id = db.lastID
                try db.run("UPDATE companies SET data = ? WHERE id = ?", [Store.json(c), c.id])
                try audit("company", c.id, "create", after: Store.json(c))
            } else {
                let before = self.company(c.id).map(Store.json)
                try db.run("UPDATE companies SET name = ?, data = ?, archived = ?, updated_at = ? WHERE id = ?", [c.name, Store.json(c), c.archived, Day.now, c.id])
                try audit("company", c.id, "update", before: before, after: Store.json(c))
            }
        }
        changed()
        return c
    }

    // MARK: Clients

    public func clients() -> [Client] {
        let rows = (try? db.run("SELECT id, data FROM clients ORDER BY name COLLATE NOCASE")) ?? []
        return rows.compactMap { r in
            guard var c = Store.decode(Client.self, r["data"]?.string) else { return nil }
            c.id = r["id"]?.int64 ?? 0
            return c
        }
    }

    public func client(_ id: Int64) -> Client? {
        guard let r = try? db.run("SELECT id, data FROM clients WHERE id = ?", [id]).first, var c = Store.decode(Client.self, r["data"]?.string) else { return nil }
        c.id = id
        return c
    }

    public func searchClients(_ q: String, limit: Int = 20) -> [Client] {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return Array(clients().prefix(limit)) }
        let digits = t.filter(\.isNumber)
        return Array(clients().filter {
            $0.name.localizedCaseInsensitiveContains(t) || (!digits.isEmpty && ($0.ico.filter(\.isNumber).hasPrefix(digits) || $0.dic.contains(digits)))
                || $0.email.localizedCaseInsensitiveContains(t)
        }.prefix(limit))
    }

    @discardableResult
    public func save(_ client: Client) throws -> Client {
        var c = client
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty else { throw FakturyError("Odberateľ musí mať názov.") }
        try db.transaction {
            if c.id == 0 {
                try db.run("INSERT INTO clients(name, ico, data, created_at, updated_at) VALUES (?,?,?,?,?)", [c.name, c.ico, "{}", Day.now, Day.now])
                c.id = db.lastID
                try db.run("UPDATE clients SET data = ? WHERE id = ?", [Store.json(c), c.id])
                try audit("client", c.id, "create", after: Store.json(c))
            } else {
                let before = self.client(c.id).map(Store.json)
                try db.run("UPDATE clients SET name = ?, ico = ?, data = ?, updated_at = ? WHERE id = ?", [c.name, c.ico, Store.json(c), Day.now, c.id])
                try audit("client", c.id, "update", before: before, after: Store.json(c))
            }
        }
        changed()
        return c
    }

    public func deleteClient(_ id: Int64) throws {
        let used = (try db.run("SELECT COUNT(*) AS n FROM invoices WHERE client_id = ? AND status <> 'draft'", [id]).first?["n"]?.int) ?? 0
        guard used == 0 else { throw FakturyError("Odberateľ má vystavené doklady, nedá sa zmazať.") }
        let before = client(id).map(Store.json)
        try db.transaction {
            try db.run("UPDATE invoices SET client_id = NULL WHERE client_id = ? AND status = 'draft'", [id])
            try db.run("DELETE FROM clients WHERE id = ?", [id])
            try audit("client", id, "delete", before: before)
        }
        changed()
    }

    // MARK: Invoices

    public struct Filter {
        public var companyId: Int64?
        public var clientId: Int64?
        public var status: InvoiceStatus?
        public var kind: InvoiceKind?
        public var unpaid = false
        public var overdue = false
        public var from: String?
        public var to: String?
        public var query: String?
        public var limit = 10_000
        public init(companyId: Int64? = nil, status: InvoiceStatus? = nil) { self.companyId = companyId; self.status = status }
    }

    static let select = """
        SELECT i.*,
          (SELECT COALESCE(SUM(-c.total_cents), 0) FROM invoices c WHERE c.credits_invoice_id = i.id AND c.status = 'issued') AS credited,
          (SELECT o.number FROM invoices o WHERE o.id = i.credits_invoice_id) AS credits_number,
          (SELECT o.issue_date FROM invoices o WHERE o.id = i.credits_invoice_id) AS credits_issue_date
        FROM invoices i
        """

    public func invoices(_ f: Filter = Filter()) -> [Invoice] {
        var sql = Store.select + " WHERE 1=1", args: [Any?] = []
        if let c = f.companyId { sql += " AND i.company_id = ?"; args.append(c) }
        if let c = f.clientId { sql += " AND i.client_id = ?"; args.append(c) }
        if let s = f.status { sql += " AND i.status = ?"; args.append(s.rawValue) }
        if let k = f.kind { sql += " AND i.kind = ?"; args.append(k.rawValue) }
        if let d = f.from { sql += " AND COALESCE(i.issue_date, '') >= ?"; args.append(d) }
        if let d = f.to { sql += " AND COALESCE(i.issue_date, '') <= ?"; args.append(d) }
        sql += " ORDER BY i.status = 'draft' DESC, i.issue_date DESC, i.number DESC, i.id DESC"
        let rows = (try? db.run(sql, args)) ?? []
        let items = itemsByInvoice(rows.compactMap { $0["id"]?.int64 })
        var list = rows.map { invoice(from: $0, items: items[$0["id"]?.int64 ?? 0] ?? []) }
        if f.unpaid { list = list.filter { $0.balanceCents > 0 } }
        if f.overdue { list = list.filter(\.isOverdue) }
        if let q = f.query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            list = list.filter { ($0.number ?? "").contains(q) || $0.client.name.localizedCaseInsensitiveContains(q) || $0.client.ico.contains(q)
                || $0.items.contains { $0.description.localizedCaseInsensitiveContains(q) } || $0.note.localizedCaseInsensitiveContains(q) }
        }
        return Array(list.prefix(f.limit))
    }

    public func invoice(_ id: Int64) -> Invoice? {
        guard let r = try? db.run(Store.select + " WHERE i.id = ?", [id]).first else { return nil }
        return invoice(from: r, items: itemsByInvoice([id])[id] ?? [])
    }

    public func invoice(number: String, companyId: Int64? = nil) -> Invoice? {
        guard let r = try? db.run(Store.select + " WHERE i.number = ? AND (? IS NULL OR i.company_id = ?) ORDER BY i.id DESC", [number, companyId, companyId]).first,
              let id = r["id"]?.int64 else { return nil }
        return invoice(from: r, items: itemsByInvoice([id])[id] ?? [])
    }

    func itemsByInvoice(_ ids: [Int64]) -> [Int64: [Item]] {
        guard !ids.isEmpty else { return [:] }
        let rows = (try? db.run("SELECT * FROM invoice_items WHERE invoice_id IN (\(ids.map(String.init).joined(separator: ","))) ORDER BY invoice_id, position")) ?? []
        var out: [Int64: [Item]] = [:]
        for r in rows {
            var i = Item(description: r["description"]?.string ?? "", quantity: r["quantity"]?.double ?? 0, unit: r["unit"]?.string ?? "",
                         unitPriceCents: r["unit_price_cents"]?.int ?? 0, vatRate: r["vat_rate"]?.double ?? 0)
            if let u = r["uuid"]?.string, let id = UUID(uuidString: u) { i.id = id }
            out[r["invoice_id"]?.int64 ?? 0, default: []].append(i)
        }
        return out
    }

    func invoice(from r: Row, items: [Item]) -> Invoice {
        var i = Invoice()
        i.id = r["id"]?.int64 ?? 0
        i.companyId = r["company_id"]?.int64 ?? 0
        i.kind = InvoiceKind(rawValue: r["kind"]?.string ?? "") ?? .invoice
        i.status = InvoiceStatus(rawValue: r["status"]?.string ?? "") ?? .draft
        i.number = r["number"]?.string
        i.variableSymbol = r["variable_symbol"]?.string ?? ""
        i.clientId = r["client_id"]?.int64
        i.client = Store.decode(Client.self, r["client_snapshot"]?.string) ?? Client()
        i.supplier = Store.decode(Company.self, r["supplier_snapshot"]?.string)
        i.issueDate = r["issue_date"]?.string ?? Day.today
        i.deliveryDate = r["delivery_date"]?.string ?? i.issueDate
        i.dueDate = r["due_date"]?.string ?? i.issueDate
        i.currency = r["currency"]?.string ?? "EUR"
        i.paymentMethod = PaymentMethod(rawValue: r["payment_method"]?.string ?? "") ?? .transfer
        i.vatMode = VatMode(rawValue: r["vat_mode"]?.string ?? "") ?? .nonPayer
        i.vatNote = r["vat_note"]?.string ?? ""
        i.creditsInvoiceId = r["credits_invoice_id"]?.int64
        i.creditsNumber = r["credits_number"]?.string
        i.creditsIssueDate = r["credits_issue_date"]?.string
        i.creditReason = r["credit_reason"]?.string ?? ""
        i.proformaId = r["proforma_id"]?.int64
        i.note = r["note"]?.string ?? ""
        i.internalNote = r["internal_note"]?.string ?? ""
        i.items = items
        i.subtotalCents = r["subtotal_cents"]?.int ?? 0
        i.vatCents = r["vat_cents"]?.int ?? 0
        i.totalCents = r["total_cents"]?.int ?? 0
        if i.isDraft { let t = i.totals; i.subtotalCents = t.subtotalCents; i.vatCents = t.vatCents; i.totalCents = t.totalCents }
        i.pdfPath = r["pdf_path"]?.string
        i.pdfSha = r["pdf_sha256"]?.string
        i.sentAt = r["sent_at"]?.string
        i.sentVia = r["sent_via"]?.string
        i.paidCents = r["paid_cents"]?.int ?? 0
        i.paidAt = r["paid_at"]?.string
        i.creditedCents = r["credited"]?.int ?? 0
        i.createdAt = r["created_at"]?.string ?? ""
        i.updatedAt = r["updated_at"]?.string ?? ""
        i.issuedAt = r["issued_at"]?.string
        i.imported = (r["imported"]?.int ?? 0) == 1
        return i
    }

    /// A fresh draft for a subject: its VAT mode, due days and today's dates.
    public func newDraft(companyId: Int64, kind: InvoiceKind = .invoice, client: Client? = nil) throws -> Invoice {
        guard let c = company(companyId) else { throw FakturyError("Subjekt neexistuje.") }
        var i = Invoice()
        i.companyId = companyId
        i.kind = kind
        i.vatMode = c.vatPayer ? .standard : .nonPayer
        i.items = [Item(vatRate: c.vatPayer ? 23 : 0)]
        i.dueDate = Day.adding(c.dueDays, to: i.issueDate)
        if let cl = client { i.client = cl; i.clientId = cl.id == 0 ? nil : cl.id; applyClientDefaults(&i, company: c) }
        return try saveDraft(i)
    }

    /// Reverse charge for an EU business with a VAT number when the subject is a VAT payer.
    public func applyClientDefaults(_ i: inout Invoice, company c: Company) {
        guard c.vatPayer else { i.vatMode = .nonPayer; return }
        if i.client.isForeign && !i.client.icDph.isEmpty { i.vatMode = .reverseCharge } else if i.vatMode == .reverseCharge && !i.client.isForeign { i.vatMode = .standard }
    }

    @discardableResult
    public func saveDraft(_ draft: Invoice) throws -> Invoice {
        var i = draft
        let t = i.totals
        i.subtotalCents = t.subtotalCents; i.vatCents = t.vatCents; i.totalCents = t.totalCents
        let before = i.id == 0 ? nil : invoice(i.id)
        if let b = before, !b.isDraft { throw FakturyError("Vystavený doklad sa nedá meniť. Oprav ho dobropisom.") }
        if let b = before, Store.sameContent(b, i) { return b }   // nothing changed: no write, no audit entry
        try db.transaction {
            let args: [Any?] = [i.companyId, i.kind.rawValue, i.variableSymbol, i.clientId, Store.json(i.client), i.issueDate, i.deliveryDate, i.dueDate,
                                i.currency, i.paymentMethod.rawValue, i.vatMode.rawValue, i.vatNote, i.creditsInvoiceId, i.creditReason, i.proformaId,
                                i.note, i.internalNote, i.subtotalCents, i.vatCents, i.totalCents, Day.now]
            if i.id == 0 {
                try db.run("""
                    INSERT INTO invoices(company_id, kind, variable_symbol, client_id, client_snapshot, issue_date, delivery_date, due_date, currency,
                      payment_method, vat_mode, vat_note, credits_invoice_id, credit_reason, proforma_id, note, internal_note, subtotal_cents, vat_cents,
                      total_cents, updated_at, status, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'draft',?)
                    """, args + [Day.now])
                i.id = db.lastID
            } else {
                try db.run("""
                    UPDATE invoices SET company_id=?, kind=?, variable_symbol=?, client_id=?, client_snapshot=?, issue_date=?, delivery_date=?, due_date=?,
                      currency=?, payment_method=?, vat_mode=?, vat_note=?, credits_invoice_id=?, credit_reason=?, proforma_id=?, note=?, internal_note=?,
                      subtotal_cents=?, vat_cents=?, total_cents=?, updated_at=? WHERE id = ? AND status = 'draft'
                    """, args + [i.id])
            }
            try db.run("DELETE FROM invoice_items WHERE invoice_id = ?", [i.id])
            for (n, it) in i.items.enumerated() {
                try db.run("INSERT INTO invoice_items(invoice_id, position, uuid, description, quantity, unit, unit_code, unit_price_cents, vat_rate, line_net_cents) VALUES (?,?,?,?,?,?,?,?,?,?)",
                           [i.id, n, it.id.uuidString, it.description, it.quantity, it.unit, it.unitCode, it.unitPriceCents, i.vatMode.chargesVat ? it.vatRate : 0.0, it.netCents])
            }
            try audit("invoice", i.id, before == nil ? "create_draft" : "update_draft", before: before.map(Store.json), after: Store.json(i))
        }
        changed()
        return invoice(i.id) ?? i
    }

    /// The editable content of two drafts is the same (timestamps and derived fields aside).
    static func sameContent(_ a: Invoice, _ b: Invoice) -> Bool {
        func norm(_ x: Invoice) -> Invoice {
            var y = x
            y.updatedAt = ""; y.createdAt = ""; y.creditsNumber = nil; y.creditsIssueDate = nil; y.creditedCents = 0
            y.subtotalCents = 0; y.vatCents = 0; y.totalCents = 0
            if !y.vatMode.chargesVat { y.items = y.items.map { var t = $0; t.vatRate = 0; return t } }
            return y
        }
        return norm(a) == norm(b)
    }

    public func deleteDraft(_ id: Int64) throws {
        guard let i = invoice(id) else { return }
        guard i.isDraft else { throw FakturyError("Vystavený doklad sa nedá zmazať.") }
        try db.transaction {
            try db.run("DELETE FROM invoice_items WHERE invoice_id = ?", [id])
            try db.run("DELETE FROM invoices WHERE id = ? AND status = 'draft'", [id])
            try audit("invoice", id, "delete_draft", before: Store.json(i))
        }
        changed()
    }

    /// A new draft with the same client and items (dates from today).
    public func duplicate(_ id: Int64) throws -> Invoice {
        guard let src = invoice(id), let c = company(src.companyId) else { throw FakturyError("Doklad neexistuje.") }
        var i = Invoice()
        i.companyId = src.companyId
        i.kind = src.kind == .creditNote ? .invoice : src.kind
        i.clientId = src.clientId
        i.client = src.clientId.flatMap(client) ?? src.client
        i.vatMode = src.vatMode
        i.vatNote = src.vatNote
        i.paymentMethod = src.paymentMethod
        i.items = src.items.map { var x = $0; x.id = UUID(); x.quantity = abs(x.quantity); return x }
        i.note = src.note
        i.dueDate = Day.adding(c.dueDays, to: i.issueDate)
        return try saveDraft(i)
    }

    /// A credit note draft against an issued invoice: the same items with negative quantities (edit them for a partial credit).
    public func creditNoteDraft(for id: Int64, reason: String = "") throws -> Invoice {
        guard let src = invoice(id), src.status == .issued, src.kind == .invoice else { throw FakturyError("Dobropis sa dá vystaviť len k vystavenej faktúre.") }
        var i = Invoice()
        i.companyId = src.companyId
        i.kind = .creditNote
        i.clientId = src.clientId
        i.client = src.client
        i.vatMode = src.vatMode
        i.vatNote = src.vatNote
        i.paymentMethod = src.paymentMethod
        i.creditsInvoiceId = src.id
        i.creditReason = reason
        i.items = src.items.map { var x = $0; x.id = UUID(); x.quantity = -abs(x.quantity); return x }
        i.dueDate = Day.adding(14, to: i.issueDate)
        return try saveDraft(i)
    }

    /// The final invoice after a paid proforma: same client and items, with a reference to it.
    public func invoiceFromProforma(_ id: Int64) throws -> Invoice {
        guard let src = invoice(id), src.kind == .proforma, src.status == .issued else { throw FakturyError("Treba vystavenú zálohovú faktúru.") }
        var i = try duplicate(id)
        i.kind = .invoice
        i.proformaId = src.id
        i.note = ["Uhradené zálohovou faktúrou č. \(src.number ?? "") v sume \(Money.string(src.totalCents)).", i.note].filter { !$0.isEmpty }.joined(separator: "\n")
        return try saveDraft(i)
    }

    // MARK: Numbering

    /// "{YYYY}{NNNN}" with year 2026 and 12 → "20260012". Also {YY}, {MM}; the count of N is the zero padding.
    public static func format(_ pattern: String, year: Int, month: Int, n: Int) -> String {
        var out = pattern.replacingOccurrences(of: "{YYYY}", with: String(year))
            .replacingOccurrences(of: "{YY}", with: String(format: "%02d", year % 100))
            .replacingOccurrences(of: "{MM}", with: String(format: "%02d", month))
        if let r = out.range(of: #"\{N+\}"#, options: .regularExpression) {
            let width = out[r].count - 2
            out.replaceSubrange(r, with: String(format: "%0\(width)d", n))
        } else {
            out += String(n)
        }
        return out
    }

    public func nextNumber(companyId: Int64, kind: InvoiceKind, year: Int) -> Int {
        (try? db.run("SELECT next_number FROM number_series WHERE company_id = ? AND kind = ? AND year = ?", [companyId, kind.rawValue, year]).first?["next_number"]?.int) ?? 1
    }

    public func setNextNumber(companyId: Int64, kind: InvoiceKind, year: Int, _ n: Int) throws {
        guard n >= 1 else { throw FakturyError("Číslo musí byť aspoň 1.") }
        let before = nextNumber(companyId: companyId, kind: kind, year: year)
        try db.transaction {
            try db.run("INSERT INTO number_series(company_id, kind, year, next_number) VALUES (?,?,?,?) ON CONFLICT(company_id, kind, year) DO UPDATE SET next_number = excluded.next_number",
                       [companyId, kind.rawValue, year, n])
            try audit("number_series", companyId, "set_next", before: "{\"kind\":\"\(kind.rawValue)\",\"year\":\(year),\"next\":\(before)}",
                      after: "{\"kind\":\"\(kind.rawValue)\",\"year\":\(year),\"next\":\(n)}")
        }
        changed()
    }

    /// The number the draft would get if issued now.
    public func previewNumber(_ i: Invoice) -> String? {
        guard let c = company(i.companyId) else { return nil }
        let (y, m) = Store.yearMonth(i.issueDate)
        return Store.format(c.pattern(i.kind), year: y, month: m, n: nextNumber(companyId: c.id, kind: i.kind, year: y))
    }

    static func yearMonth(_ day: String) -> (Int, Int) {
        let p = day.split(separator: "-")
        return (Int(p.first ?? "") ?? Calendar.current.component(.year, from: Date()), p.count > 1 ? Int(p[1]) ?? 1 : 1)
    }

    // MARK: Issuing

    public struct Check: Hashable {
        public var errors: [String] = []
        public var warnings: [String] = []
        public var ok: Bool { errors.isEmpty }
    }

    /// Everything a Slovak invoice must have (and what iDoklad checks for e-invoices) before it may be issued.
    public func check(_ i: Invoice) -> Check {
        var ch = Check()
        guard let c = company(i.companyId) else { ch.errors.append("Chýba subjekt (dodávateľ)."); return ch }
        let cl = i.clientId.flatMap(client) ?? i.client
        if c.name.isEmpty || c.street.isEmpty || c.city.isEmpty || c.zip.isEmpty { ch.errors.append("Subjekt \(c.name): doplň adresu (ulica, mesto, PSČ).") }
        if c.ico.isEmpty { ch.errors.append("Subjekt \(c.name): chýba IČO.") }
        if c.vatPayer && c.icDph.isEmpty { ch.errors.append("Subjekt \(c.name) je platiteľ DPH, chýba IČ DPH.") }
        if c.dic.isEmpty { ch.warnings.append("Subjekt \(c.name): chýba DIČ (pre e-faktúru od 2027 povinné).") }
        if c.registry.isEmpty { ch.warnings.append("Subjekt \(c.name): chýba údaj o zápise v registri (Obchodný zákonník § 3a).") }
        if i.paymentMethod == .transfer {
            if c.iban.isEmpty { ch.errors.append("Subjekt \(c.name): chýba IBAN.") } else if !Validation.iban(c.iban) { ch.errors.append("IBAN \(c.iban) nie je platný.") }
        }
        if cl.name.isEmpty { ch.errors.append("Chýba odberateľ.") }
        if cl.street.isEmpty || cl.city.isEmpty { ch.errors.append("Odberateľ: doplň adresu (ulica, mesto).") }
        if cl.zip.isEmpty { ch.warnings.append("Odberateľ: chýba PSČ.") }
        if cl.ico.isEmpty && !cl.isForeign { ch.warnings.append("Odberateľ bez IČO – ide o fyzickú osobu?") }
        if i.vatMode == .standard && !c.vatPayer { ch.errors.append("Subjekt nie je platiteľ DPH, faktúra nemôže byť s DPH.") }
        if i.vatMode != .standard && c.vatPayer && i.vatMode == .nonPayer { ch.errors.append("Subjekt je platiteľ DPH: zvoľ S DPH alebo prenesenie daňovej povinnosti.") }
        if i.vatMode == .reverseCharge && cl.icDph.isEmpty { ch.errors.append("Pri prenesení daňovej povinnosti treba IČ DPH odberateľa.") }
        if i.items.isEmpty { ch.errors.append("Faktúra nemá položky.") }
        for (n, it) in i.items.enumerated() where it.description.trimmingCharacters(in: .whitespaces).isEmpty { ch.errors.append("Položka \(n + 1) nemá popis.") }
        if i.items.contains(where: { $0.quantity == 0 }) { ch.warnings.append("Niektorá položka má množstvo 0.") }
        let total = i.totals.totalCents
        if i.kind == .creditNote {
            if i.creditsInvoiceId == nil { ch.errors.append("Dobropis musí odkazovať na pôvodnú faktúru.") }
            if i.creditReason.trimmingCharacters(in: .whitespaces).isEmpty { ch.errors.append("Dobropis musí mať dôvod opravy.") }
            if total >= 0 { ch.errors.append("Dobropis musí mať zápornú sumu.") }
        } else if total <= 0 { ch.errors.append("Suma faktúry musí byť kladná.") }
        if i.dueDate < i.issueDate { ch.errors.append("Splatnosť je pred dátumom vystavenia.") }
        if Day.diff(i.deliveryDate, i.issueDate) > 15 { ch.warnings.append("Faktúra sa má vyhotoviť do 15 dní od dodania (§ 73 zákona o DPH).") }
        if i.issueDate > Day.today { ch.warnings.append("Dátum vystavenia je v budúcnosti.") }
        if i.issueDate < Day.today {
            let last = (try? db.run("SELECT MAX(issue_date) AS d FROM invoices WHERE company_id = ? AND kind = ? AND status <> 'draft'", [i.companyId, i.kind.rawValue]).first?["d"]?.string) ?? nil
            if let last, last > i.issueDate { ch.warnings.append("Posledný doklad v rade má neskorší dátum (\(Day.sk(last))) – čísla by nešli podľa dátumu.") }
        }
        return ch
    }

    /// Issues a draft: number from the series, snapshots of both parties, totals, the PDF (rendered once, read-only), audit.
    @MainActor @discardableResult
    public func issue(_ id: Int64) throws -> Invoice {
        guard var i = invoice(id) else { throw FakturyError("Doklad neexistuje.") }
        guard i.isDraft else { throw FakturyError("\(i.title) už je vystavený.") }
        guard let c = company(i.companyId) else { throw FakturyError("Subjekt neexistuje.") }
        let ch = check(i)
        guard ch.ok else { throw FakturyError(ch.errors.joined(separator: "\n")) }
        let before = Store.json(i)
        if let cid = i.clientId, let live = client(cid) { i.client = live }
        i.supplier = c
        let (y, m) = Store.yearMonth(i.issueDate)
        let n = nextNumber(companyId: c.id, kind: i.kind, year: y)
        let number = Store.format(c.pattern(i.kind), year: y, month: m, n: n)
        if invoice(number: number, companyId: c.id).map({ $0.kind == i.kind }) == true {
            throw FakturyError("Číslo \(number) už existuje. Uprav ďalšie číslo v rade (Nastavenia → \(c.shortName)).")
        }
        i.number = number
        if i.variableSymbol.isEmpty { i.variableSymbol = String(number.filter(\.isNumber).suffix(10)) }
        let t = i.totals
        i.subtotalCents = t.subtotalCents; i.vatCents = t.vatCents; i.totalCents = t.totalCents
        i.status = .issued
        i.issuedAt = Day.now
        if i.vatMode == .reverseCharge && i.vatNote.isEmpty { i.vatNote = "Prenesenie daňovej povinnosti" }

        // the PDF first, so a failed render issues nothing
        let pdf = try InvoicePDF.render(i, company: c)
        let file = pdfDir.appendingPathComponent("\(c.id)/\(y)/\(i.kind.filePrefix)-\(number.replacingOccurrences(of: "/", with: "-")).pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try FileManager.default.removeItem(at: file)
        }
        try pdf.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        i.pdfPath = file.path
        i.pdfSha = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()

        do {
            try db.transaction {
                // the series must not have moved since we read it
                let now = nextNumber(companyId: c.id, kind: i.kind, year: y)
                guard now == n else { throw FakturyError("Číselný rad sa medzitým zmenil, skús znova.") }
                try db.run("INSERT INTO number_series(company_id, kind, year, next_number) VALUES (?,?,?,?) ON CONFLICT(company_id, kind, year) DO UPDATE SET next_number = excluded.next_number",
                           [c.id, i.kind.rawValue, y, n + 1])
                try db.run("UPDATE invoice_items SET line_net_cents = line_net_cents WHERE invoice_id = ?", [i.id])
                try db.run("""
                    UPDATE invoices SET status = 'issued', number = ?, variable_symbol = ?, client_snapshot = ?, supplier_snapshot = ?, subtotal_cents = ?,
                      vat_cents = ?, total_cents = ?, vat_note = ?, pdf_path = ?, pdf_sha256 = ?, issued_at = ?, updated_at = ? WHERE id = ? AND status = 'draft'
                    """, [number, i.variableSymbol, Store.json(i.client), Store.json(c), i.subtotalCents, i.vatCents, i.totalCents, i.vatNote,
                          i.pdfPath, i.pdfSha, i.issuedAt, Day.now, i.id])
                try audit("invoice", i.id, "issue", before: before, after: Store.json(i))
            }
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        changed()
        Backup.afterIssue(self, invoice: i, company: c)
        return invoice(i.id) ?? i
    }

    /// Proformas are not tax documents and may be cancelled (they keep their number).
    public func cancelProforma(_ id: Int64) throws {
        guard let i = invoice(id), i.kind == .proforma, i.status == .issued else { throw FakturyError("Zrušiť sa dá len vystavená zálohová faktúra.") }
        try db.transaction {
            try db.run("UPDATE invoices SET status = 'cancelled', updated_at = ? WHERE id = ?", [Day.now, id])
            try audit("invoice", id, "cancel", before: Store.json(i))
        }
        changed()
    }

    // MARK: After issuing: notes, sending, payments

    public func setNotes(_ id: Int64, internalNote: String) throws {
        let before = invoice(id).map(Store.json)
        try db.transaction {
            try db.run("UPDATE invoices SET internal_note = ?, updated_at = ? WHERE id = ?", [internalNote, Day.now, id])
            try audit("invoice", id, "internal_note", before: before, after: "\"\(internalNote)\"")
        }
        changed()
    }

    public func markSent(_ id: Int64, via: String = "manual", at: String = Day.now) throws {
        guard let i = invoice(id), i.status == .issued else { throw FakturyError("Odoslať sa dá len vystavený doklad.") }
        try db.transaction {
            try db.run("UPDATE invoices SET sent_at = ?, sent_via = ?, updated_at = ? WHERE id = ?", [at, via, Day.now, id])
            try audit("invoice", id, "sent", after: "{\"via\":\"\(via)\"}")
        }
        changed()
    }

    public func payments(_ invoiceId: Int64) -> [Payment] {
        ((try? db.run("SELECT * FROM payments WHERE invoice_id = ? ORDER BY date, id", [invoiceId])) ?? []).map {
            Payment(id: $0["id"]?.int64 ?? 0, invoiceId: invoiceId, date: $0["date"]?.string ?? "", amountCents: $0["amount_cents"]?.int ?? 0,
                    method: $0["method"]?.string ?? "", note: $0["note"]?.string ?? "")
        }
    }

    /// Records a payment (nil amount = the whole balance).
    @discardableResult
    public func addPayment(_ invoiceId: Int64, amountCents: Int? = nil, date: String = Day.today, method: String = "transfer",
                           source: String = "manual", note: String = "") throws -> Invoice {
        guard let i = invoice(invoiceId), i.status == .issued, i.kind != .creditNote else { throw FakturyError("Úhrada sa dá zapísať len k vystavenej faktúre.") }
        let amount = amountCents ?? i.balanceCents
        guard amount != 0 else { throw FakturyError("Faktúra je už uhradená.") }
        try db.transaction {
            try db.run("INSERT INTO payments(invoice_id, date, amount_cents, method, source, note, created_at) VALUES (?,?,?,?,?,?,?)",
                       [invoiceId, date, amount, method, source, note, Day.now])
            let pid = db.lastID
            try recomputePaid(invoiceId)
            try audit("payment", pid, "create", after: "{\"invoice\":\(invoiceId),\"amount_cents\":\(amount),\"date\":\"\(date)\"}")
        }
        changed()
        return invoice(invoiceId) ?? i
    }

    public func deletePayment(_ paymentId: Int64) throws {
        guard let r = try db.run("SELECT * FROM payments WHERE id = ?", [paymentId]).first, let inv = r["invoice_id"]?.int64 else { return }
        try db.transaction {
            try db.run("DELETE FROM payments WHERE id = ?", [paymentId])
            try recomputePaid(inv)
            try audit("payment", paymentId, "delete", before: "{\"invoice\":\(inv),\"amount_cents\":\(r["amount_cents"]?.int ?? 0),\"date\":\"\(r["date"]?.string ?? "")\"}")
        }
        changed()
    }

    func recomputePaid(_ invoiceId: Int64) throws {
        let rows = try db.run("SELECT COALESCE(SUM(amount_cents), 0) AS s, MAX(date) AS d FROM payments WHERE invoice_id = ?", [invoiceId])
        let paid = rows.first?["s"]?.int ?? 0
        guard let i = invoice(invoiceId) else { return }
        let full = paid + i.creditedCents >= i.totalCents
        try db.run("UPDATE invoices SET paid_cents = ?, paid_at = ?, updated_at = ? WHERE id = ?", [paid, full ? rows.first?["d"]?.string : nil, Day.now, invoiceId])
    }

    // MARK: Overview

    public struct MonthTotal: Hashable, Identifiable { public var id: String { month }; public let month: String; public let netCents: Int; public let totalCents: Int; public let count: Int }

    /// Issued invoices and credit notes (not proformas) per month of issue.
    public func monthly(companyId: Int64?, year: Int) -> [MonthTotal] {
        let rows = (try? db.run("""
            SELECT substr(issue_date, 1, 7) AS m, SUM(subtotal_cents) AS net, SUM(total_cents) AS tot, COUNT(*) AS n FROM invoices
            WHERE status = 'issued' AND kind IN ('invoice', 'credit_note') AND substr(issue_date, 1, 4) = ? AND (? IS NULL OR company_id = ?)
            GROUP BY m ORDER BY m
            """, [String(year), companyId, companyId])) ?? []
        return rows.map { MonthTotal(month: $0["m"]?.string ?? "", netCents: $0["net"]?.int ?? 0, totalCents: $0["tot"]?.int ?? 0, count: $0["n"]?.int ?? 0) }
    }
}

public enum Validation {
    /// ISO 13616 mod-97 check.
    public static func iban(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "").uppercased()
        guard t.count >= 15, t.count <= 34, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let moved = t.dropFirst(4) + t.prefix(4)
        var rem = 0
        for ch in moved {
            if let d = ch.wholeNumberValue { rem = (rem * 10 + d) % 97 }
            else if let a = ch.asciiValue, ch.isLetter { let v = Int(a) - 55; rem = (rem * 100 + v) % 97 } else { return false }
        }
        return rem == 1
    }

    /// Spaced in groups of four, as printed on invoices.
    public static func formatIBAN(_ s: String) -> String {
        let t = s.replacingOccurrences(of: " ", with: "").uppercased()
        return stride(from: 0, to: t.count, by: 4).map { i -> String in
            let a = t.index(t.startIndex, offsetBy: i), b = t.index(a, offsetBy: min(4, t.count - i))
            return String(t[a..<b])
        }.joined(separator: " ")
    }
}
