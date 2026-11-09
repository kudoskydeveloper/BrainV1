import Foundation
import Testing
@testable import FakturyCore

@MainActor @Suite(.serialized) struct StoreTests {
    let store: Store
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("faktury-test-\(UUID().uuidString)")
        setenv("FAKTURY_BACKUP_DIR", dir.appendingPathComponent("icloud").path, 1)
        store = try Store(dir: dir)
        store.notify = false
    }

    func company(vat: Bool = false) throws -> Company {
        var c = Company()
        c.name = vat ? "Vzorová Firma s.r.o." : "Ján Vzor"
        c.legalForm = vat ? .company : .soleTrader
        c.street = "Hlavná 1"; c.city = "Bratislava"; c.zip = "811 01"
        c.ico = "12345678"; c.dic = "2020202020"; c.icDph = vat ? "SK2020202020" : ""; c.vatPayer = vat
        c.iban = "SK31 1200 0000 1987 4263 7541"; c.swift = "TATRSKBX"
        c.registry = "Zapísaná v OR"
        return try store.save(c)
    }

    func client() throws -> Client {
        var c = Client(); c.name = "TROMF, a.s."; c.street = "Podhájska 247/10"; c.city = "Marianka"; c.zip = "900 33"; c.ico = "35724951"
        c.dic = "2020000000"; c.icDph = "SK2020000000"; c.email = "faktury@example.com"
        return try store.save(c)
    }

    func draft(_ co: Company, _ cl: Client, price: Int = 100_000) throws -> Invoice {
        var d = try store.newDraft(companyId: co.id, client: cl)
        d.items = [Item(description: "Web", quantity: 1, unit: "ks", unitPriceCents: price, vatRate: 23),
                   Item(description: "Správa", quantity: 2.5, unit: "hod", unitPriceCents: 4_000, vatRate: 23)]
        return try store.saveDraft(d)
    }

    @Test func numberFormat() {
        #expect(Store.format("{YYYY}{NNNN}", year: 2026, month: 11, n: 12) == "20260012")
        #expect(Store.format("FA{YY}{MM}{NNN}", year: 2026, month: 3, n: 7) == "FA2603007")
        #expect(Store.format("{YYYY}/", year: 2026, month: 1, n: 5) == "2026/5")
    }

    @Test func iban() {
        #expect(Validation.iban("SK31 1200 0000 1987 4263 7541"))
        #expect(!Validation.iban("SK31 1200 0000 1987 4263 7542"))
        #expect(Validation.formatIBAN("SK3112000000198742637541") == "SK31 1200 0000 1987 4263 7541")
    }

    @Test func vatTotals() {
        let items = [Item(description: "a", quantity: 3, unitPriceCents: 3333, vatRate: 23), Item(description: "b", quantity: 1, unitPriceCents: 1001, vatRate: 5)]
        let t = Totals.compute(items, mode: .standard)
        #expect(t.subtotalCents == 9999 + 1001)
        #expect(t.groups.first { $0.rate == 23 }?.vatCents == 2300)   // 99.99 * 0.23 = 22.9977
        #expect(t.groups.first { $0.rate == 5 }?.vatCents == 50)      // 10.01 * 0.05 = 0.5005
        #expect(Totals.compute(items, mode: .nonPayer).vatCents == 0)
    }

    @Test func issueNumbersAndLocks() throws {
        let co = try company(vat: true), cl = try client()
        try store.setNextNumber(companyId: co.id, kind: .invoice, year: Int(Day.today.prefix(4))!, 41)
        let d1 = try draft(co, cl)
        #expect(store.previewNumber(d1) == "\(Day.today.prefix(4))0041")
        let i1 = try store.issue(d1.id)
        #expect(i1.number == "\(Day.today.prefix(4))0041")
        #expect(i1.variableSymbol == "\(Day.today.prefix(4))0041")
        #expect(i1.totalCents == Int((Double(110_000) * 1.23).rounded()))
        #expect(i1.supplier?.name == co.name)
        #expect(FileManager.default.fileExists(atPath: i1.pdfPath ?? ""))
        // a deleted draft leaves no gap
        let tmp = try draft(co, cl); try store.deleteDraft(tmp.id)
        let i2 = try store.issue(try draft(co, cl).id)
        #expect(i2.number == "\(Day.today.prefix(4))0042")
        // locked: the database itself refuses
        #expect(throws: (any Error).self) { try store.db.run("UPDATE invoices SET total_cents = 1 WHERE id = ?", [i1.id]) }
        #expect(throws: (any Error).self) { try store.db.run("UPDATE invoice_items SET unit_price_cents = 1 WHERE invoice_id = ?", [i1.id]) }
        #expect(throws: (any Error).self) { try store.db.run("DELETE FROM invoices WHERE id = ?", [i1.id]) }
        #expect(throws: (any Error).self) { try store.saveDraft(i1) }
        #expect(throws: (any Error).self) { try store.db.run("DELETE FROM audit_log") }
        // notes and payments still allowed
        try store.setNotes(i1.id, internalNote: "ok")
        try store.addPayment(i1.id, amountCents: 1000)
        #expect(store.invoice(i1.id)?.balanceCents == i1.totalCents - 1000)
        try store.addPayment(i1.id)
        #expect(store.invoice(i1.id)?.isPaid == true)
        #expect(store.auditLog(entity: "invoice", id: i1.id).contains { $0.action == "issue" })
        if let keep = ProcessInfo.processInfo.environment["FAKTURY_PDF_OUT1"] { try? FileManager.default.copyItem(atPath: i1.pdfPath!, toPath: keep) }
    }

    @Test func creditNote() throws {
        let co = try company(vat: true), cl = try client()
        let inv = try store.issue(try draft(co, cl).id)
        var cn = try store.creditNoteDraft(for: inv.id)
        #expect(cn.totals.totalCents == -inv.totalCents)
        #expect(throws: (any Error).self) { try store.issue(cn.id) }   // no reason yet
        cn.creditReason = "Zľava po dohode"
        cn.items = [Item(description: "Zľava na web", quantity: -1, unit: "ks", unitPriceCents: 10_000, vatRate: 23)]
        cn = try store.saveDraft(cn)
        let issued = try store.issue(cn.id)
        #expect(issued.number?.hasPrefix("D") == true)
        #expect(issued.creditsNumber == inv.number)
        #expect(store.invoice(inv.id)?.balanceCents == inv.totalCents - 12_300)
    }

    @Test func nonPayerChecks() throws {
        let co = try company(vat: false), cl = try client()
        var d = try draft(co, cl)
        #expect(d.vatMode == .nonPayer)
        d.vatMode = .standard
        #expect(!store.check(d).ok)
        d.vatMode = .nonPayer
        #expect(store.check(d).ok)
        let i = try store.issue(try store.saveDraft(d).id)
        #expect(i.vatCents == 0)
        #expect(i.totalCents == 110_000)
    }

    @Test func missingDataBlocksIssue() throws {
        var co = try company(vat: false); co.iban = "SK00 1234"; co = try store.save(co)
        let d = try store.newDraft(companyId: co.id)
        let ch = store.check(d)
        #expect(ch.errors.contains { $0.contains("IBAN") })
        #expect(ch.errors.contains { $0.contains("odberateľ") || $0.contains("Odberateľ") })
        #expect(throws: (any Error).self) { try store.issue(d.id) }
    }

    @Test func pdfAndExport() throws {
        let co = try company(vat: true), cl = try client()
        var d = try draft(co, cl)
        d.items = (1...40).map { Item(description: "Položka \($0)", quantity: 1, unit: "ks", unitPriceCents: 1000, vatRate: 23) }
        d = try store.saveDraft(d)
        #expect(InvoicePDF.pages(d.items).count >= 2)
        let i = try store.issue(d.id)
        let pdf = try Data(contentsOf: URL(fileURLWithPath: i.pdfPath!))
        #expect(pdf.count > 5000)
        let out = try AccountantExport.export(store, companyId: co.id, month: String(Day.today.prefix(7)), to: dir.appendingPathComponent("export"))
        let csv = try String(contentsOf: out.appendingPathComponent("prehlad-\(Day.today.prefix(7)).csv"), encoding: .utf8)
        #expect(csv.contains(i.number!))
        if let keep = ProcessInfo.processInfo.environment["FAKTURY_PDF_OUT"] { try? pdf.write(to: URL(fileURLWithPath: keep)) }
    }

    @Test func importOldInvoices() throws {
        let co = try company(vat: true)
        let pdf = dir.appendingPathComponent("old.pdf")
        try InvoicePDF.render(try draft(co, try client()), company: co).write(to: pdf)
        var cl = Client(); cl.name = "Stará firma s.r.o."; cl.street = "Dlhá 3"; cl.city = "Košice"; cl.ico = "11111111"
        let y = Int(Day.today.prefix(4))!
        var d = ImportedInvoice(companyId: co.id, number: "\(y)0007", issueDate: "\(y)-03-10", client: cl, vatMode: .standard, totalCents: 123_000)
        d.subtotalCents = 100_000; d.vatCents = 23_000; d.paidCents = 123_000; d.paidDate = "\(y)-03-20"; d.pdf = pdf
        let i = try store.importInvoice(d)
        #expect(i.imported && i.status == .issued && i.isPaid)
        #expect(i.totalCents == 123_000 && i.items.count == 1 && i.items[0].vatRate == 23)
        #expect(store.nextNumber(companyId: co.id, kind: .invoice, year: y) == 8)
        #expect(FileManager.default.fileExists(atPath: i.pdfPath ?? ""))
        #expect(store.clients().contains { $0.ico == "11111111" })
        #expect(store.monthly(companyId: co.id, year: y).contains { $0.month == "\(y)-03" && $0.netCents == 100_000 })
        #expect(throws: (any Error).self) { try store.importInvoice(d) }                       // same number twice
        #expect(throws: (any Error).self) { try store.db.run("UPDATE invoices SET imported = 0 WHERE id = ?", [i.id]) }
        var bad = d; bad.number = "\(y)0009"; bad.pdf = nil
        bad.items = [Item(description: "x", quantity: 1, unitPriceCents: 50_000, vatRate: 23)]
        #expect(throws: (any Error).self) { try store.importInvoice(bad) }                      // items don't add up
        var unpaid = d; unpaid.number = "\(y)0003"; unpaid.pdf = nil; unpaid.paidCents = 0; unpaid.dueDate = "\(y)-04-01"
        let u = try store.importInvoice(unpaid)
        #expect(u.isOverdue && store.nextNumber(companyId: co.id, kind: .invoice, year: y) == 8)
    }

    @Test func templates() throws {
        let co = try company(vat: false), cl = try client()
        let inv = try store.issue(try draft(co, cl).id)
        let t = try store.saveTemplate(from: inv.id, name: "Mesačná licencia")
        #expect(t.items.count == 2 && t.dueDays == 14)
        let d1 = try store.draft(fromTemplate: t.id), d2 = try store.draft(fromTemplate: t.id)
        #expect(d1.isDraft && d2.isDraft && d1.id != d2.id && d1.totals.totalCents == inv.totalCents && d1.clientId == cl.id)
        _ = try store.saveTemplate(from: d1.id, name: "Mesačná licencia")          // same name: replaced, not added
        #expect(store.templates().count == 1)
        try store.deleteTemplate(t.id)
        #expect(store.templates().isEmpty && store.invoice(d1.id) != nil)
    }

    @Test func deleteIssued() throws {
        let co = try company(vat: false), cl = try client()
        let y = Int(Day.today.prefix(4))!
        let a = try store.issue(try draft(co, cl).id), b = try store.issue(try draft(co, cl).id)
        #expect(store.deleteBlocker(a) != nil)                 // not the last one
        try store.deleteDocument(b.id)
        #expect(store.invoice(b.id) == nil && store.nextNumber(companyId: co.id, kind: .invoice, year: y) == 2)
        #expect(!FileManager.default.fileExists(atPath: b.pdfPath!))
        #expect(store.auditLog(entity: "invoice", id: b.id).contains { $0.action == "delete_issued" })
        try store.markSent(a.id)
        #expect(throws: (any Error).self) { try store.deleteDocument(a.id) }   // sent: credit note instead
        #expect(throws: (any Error).self) { try store.db.run("DELETE FROM invoices WHERE id = ?", [a.id]) }   // locks are back
        let c = try store.issue(try draft(co, cl).id)
        #expect(c.number == b.number)                           // the number is reused, no gap
    }
}
