import Foundation

/// Deleting an issued document is the exception: a test or a mistake caught before it left. Only the newest document of its
/// series that was neither sent nor paid (the series then steps back, so no gap appears), or an imported archive record.
/// Anything else is corrected with a credit note. The audit log keeps the whole deleted document.
extension Store {
    /// nil when the document may be deleted, otherwise why not.
    public func deleteBlocker(_ i: Invoice) -> String? {
        if i.isDraft { return nil }
        if i.imported { return nil }
        if i.sentAt != nil { return "Doklad už bol odoslaný odberateľovi – oprav ho dobropisom." }
        if i.paidCents != 0 || !payments(i.id).isEmpty { return "K dokladu je zapísaná úhrada – oprav ho dobropisom." }
        if invoices().contains(where: { $0.creditsInvoiceId == i.id }) { return "K faktúre existuje dobropis." }
        guard let c = company(i.companyId), let number = i.number else { return "Subjekt neexistuje." }
        let (y, m) = Store.yearMonth(i.issueDate)
        let next = nextNumber(companyId: c.id, kind: i.kind, year: y)
        if next < 2 || Store.format(c.pattern(i.kind), year: y, month: m, n: next - 1) != number {
            return "Zmazať sa dá len posledný doklad v rade (inak by v číslovaní vznikla diera) – oprav ho dobropisom."
        }
        return nil
    }

    public func deleteDocument(_ id: Int64) throws {
        guard let i = invoice(id) else { return }
        if i.isDraft { try deleteDraft(id); return }
        if let why = deleteBlocker(i) { throw FakturyError(why) }
        let (y, _) = Store.yearMonth(i.issueDate)
        try db.transaction {
            // the delete locks are lifted for this one statement and put back right away (DDL is transactional in SQLite)
            try db.exec("DROP TRIGGER IF EXISTS invoices_no_delete; DROP TRIGGER IF EXISTS items_locked_d;")
            try db.run("DELETE FROM payments WHERE invoice_id = ?", [id])
            try db.run("DELETE FROM invoice_items WHERE invoice_id = ?", [id])
            try db.run("DELETE FROM invoices WHERE id = ?", [id])
            try db.exec("""
            CREATE TRIGGER invoices_no_delete BEFORE DELETE ON invoices WHEN OLD.status <> 'draft'
            BEGIN SELECT RAISE(ABORT, 'FAKTURY: Vystavený doklad sa nedá zmazať.'); END;
            CREATE TRIGGER items_locked_d BEFORE DELETE ON invoice_items WHEN (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft'
            BEGIN SELECT RAISE(ABORT, 'FAKTURY: Položky vystaveného dokladu sa nedajú meniť.'); END;
            """)
            if !i.imported {
                let next = nextNumber(companyId: i.companyId, kind: i.kind, year: y)
                try db.run("UPDATE number_series SET next_number = ? WHERE company_id = ? AND kind = ? AND year = ?", [next - 1, i.companyId, i.kind.rawValue, y])
            }
            try audit("invoice", id, i.imported ? "delete_imported" : "delete_issued", before: Store.json(i))
        }
        // the PDF and its iCloud copy (an imported original stays in Import/Hotové)
        if let p = i.pdfPath {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p)
            try? FileManager.default.removeItem(atPath: p)
            if let c = company(i.companyId) {
                let mirror = Backup.root.appendingPathComponent(Backup.safe(c.shortName)).appendingPathComponent(String(i.issueDate.prefix(4)))
                    .appendingPathComponent(URL(fileURLWithPath: p).lastPathComponent)
                try? FileManager.default.removeItem(at: mirror)
            }
        }
        changed()
    }
}
