import Foundation

/// A reusable invoice: client, items and terms without dates or number. A new draft is made from it each time, so it is never
/// "used up" like a draft is when issued (monthly invoices to the same client, the same licence, …).
public struct InvoiceTemplate: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var companyId: Int64 = 0
    public var name = ""
    public var kind: InvoiceKind = .invoice
    public var clientId: Int64?
    public var client = Client()
    public var items: [Item] = []
    public var vatMode: VatMode = .nonPayer
    public var vatNote = ""
    public var paymentMethod: PaymentMethod = .transfer
    public var dueDays: Int?
    public var note = ""
    public var updatedAt = ""
    public init() {}

    public var totalCents: Int { Totals.compute(items, mode: vatMode).totalCents }
}

extension Store {
    func migrateTemplates() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS templates(id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL, name TEXT NOT NULL, data TEXT NOT NULL, updated_at TEXT, UNIQUE(company_id, name));")
    }

    public func templates(companyId: Int64? = nil) -> [InvoiceTemplate] {
        let rows = (try? db.run("SELECT id, data FROM templates WHERE (? IS NULL OR company_id = ?) ORDER BY name COLLATE NOCASE", [companyId, companyId])) ?? []
        return rows.compactMap { r in
            guard var t = Store.decode(InvoiceTemplate.self, r["data"]?.string) else { return nil }
            t.id = r["id"]?.int64 ?? 0
            if let cid = t.clientId, let live = client(cid) { t.client = live }
            return t
        }
    }

    public func template(_ id: Int64) -> InvoiceTemplate? { templates().first { $0.id == id } }

    /// Saves a template; a template of the same subject with the same name is replaced.
    @discardableResult
    public func save(_ template: InvoiceTemplate) throws -> InvoiceTemplate {
        var t = template
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        guard !t.name.isEmpty else { throw FakturyError("Šablóna musí mať názov.") }
        guard company(t.companyId) != nil else { throw FakturyError("Subjekt neexistuje.") }
        t.updatedAt = Day.now
        try db.transaction {
            if t.id == 0, let same = try db.run("SELECT id FROM templates WHERE company_id = ? AND name = ?", [t.companyId, t.name]).first?["id"]?.int64 { t.id = same }
            if t.id == 0 {
                try db.run("INSERT INTO templates(company_id, name, data, updated_at) VALUES (?,?,?,?)", [t.companyId, t.name, "{}", t.updatedAt])
                t.id = db.lastID
                try audit("template", t.id, "create", after: Store.json(t))
            } else {
                let before = self.template(t.id).map(Store.json)
                try db.run("UPDATE templates SET company_id = ?, name = ?, updated_at = ? WHERE id = ?", [t.companyId, t.name, t.updatedAt, t.id])
                try audit("template", t.id, "update", before: before, after: Store.json(t))
            }
            try db.run("UPDATE templates SET data = ? WHERE id = ?", [Store.json(t), t.id])
        }
        changed()
        return t
    }

    /// A template from any document (draft or issued): its client, items and terms.
    @discardableResult
    public func saveTemplate(from invoiceId: Int64, name: String) throws -> InvoiceTemplate {
        guard let i = invoice(invoiceId) else { throw FakturyError("Doklad neexistuje.") }
        var t = InvoiceTemplate()
        t.companyId = i.companyId
        t.name = name
        t.kind = i.kind == .creditNote ? .invoice : i.kind
        t.clientId = i.clientId
        t.client = i.client
        t.items = i.items.map { var x = $0; x.id = UUID(); x.quantity = abs(x.quantity); return x }
        t.vatMode = i.vatMode
        t.vatNote = i.vatMode == .reverseCharge ? "" : i.vatNote
        t.paymentMethod = i.paymentMethod
        t.dueDays = max(0, Day.diff(i.issueDate, i.dueDate))
        t.note = i.note
        return try save(t)
    }

    public func deleteTemplate(_ id: Int64) throws {
        let before = template(id).map(Store.json)
        try db.transaction {
            try db.run("DELETE FROM templates WHERE id = ?", [id])
            try audit("template", id, "delete", before: before)
        }
        changed()
    }

    /// A new draft from a template, dated today.
    public func draft(fromTemplate id: Int64) throws -> Invoice {
        guard let t = template(id), let c = company(t.companyId) else { throw FakturyError("Šablóna neexistuje.") }
        var i = Invoice()
        i.companyId = t.companyId
        i.kind = t.kind
        i.clientId = t.clientId
        i.client = t.client
        i.items = t.items.map { var x = $0; x.id = UUID(); return x }
        i.vatMode = c.vatPayer ? (t.vatMode == .nonPayer ? .standard : t.vatMode) : .nonPayer
        i.vatNote = t.vatNote
        i.paymentMethod = t.paymentMethod
        i.note = t.note
        i.dueDate = Day.adding(t.dueDays ?? c.dueDays, to: i.issueDate)
        let d = try saveDraft(i)
        try? audit("template", id, "use", after: "{\"invoice\":\(d.id)}")
        return d
    }
}
