import CryptoKit
import Foundation
import PDFKit

/// Invoices issued before Faktúry (iDoklad and others): kept as archive records with their original PDF, so the year's income,
/// unpaid invoices and clients are complete. Nothing is re-rendered or renumbered. PDFs wait in iCloud Drive › Faktúry › Import;
/// whoever reads them (Claude through MCP) fills in the fields and the user confirms.
public struct ImportedInvoice {
    public var companyId: Int64
    public var kind: InvoiceKind = .invoice
    public var number: String
    public var issueDate: String
    public var deliveryDate: String?
    public var dueDate: String?
    public var client: Client
    public var items: [Item] = []
    public var vatMode: VatMode
    public var subtotalCents: Int?
    public var vatCents: Int?
    public var totalCents: Int
    public var currency = "EUR"
    public var variableSymbol = ""
    public var paidCents = 0
    public var paidDate: String?
    public var note = ""
    public var creditsNumber: String?
    public var creditReason = ""
    public var pdf: URL?
    public init(companyId: Int64, number: String, issueDate: String, client: Client, vatMode: VatMode, totalCents: Int) {
        self.companyId = companyId; self.number = number; self.issueDate = issueDate; self.client = client; self.vatMode = vatMode; self.totalCents = totalCents
    }
}

public struct PendingImport {
    public let url: URL
    public let text: String
}

extension Store {
    public static var importDir: URL { Backup.root.appendingPathComponent("Import") }
    static var importDoneDir: URL { importDir.appendingPathComponent("Hotové") }

    /// PDFs waiting in the import folder, with their text (iDoklad and most invoicing tools write real text into the PDF).
    public func pendingImports(limit: Int = 50) -> [PendingImport] {
        try? FileManager.default.createDirectory(at: Store.importDir, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: Store.importDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.prefix(limit).map { PendingImport(url: $0, text: PDFDocument(url: $0)?.string ?? "") }
    }

    @discardableResult
    public func importInvoice(_ d: ImportedInvoice) throws -> Invoice {
        guard let company = company(d.companyId) else { throw FakturyError("Subjekt neexistuje.") }
        let number = d.number.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { throw FakturyError("Chýba číslo faktúry.") }
        if let other = invoice(number: number, companyId: company.id), other.kind == d.kind {
            throw FakturyError("\(d.kind.title) \(number) už v \(company.shortName) je (id \(other.id)).")
        }
        guard d.client.name.trimmingCharacters(in: .whitespaces).count > 0 else { throw FakturyError("Chýba odberateľ.") }
        if let p = d.pdf, !FileManager.default.fileExists(atPath: p.path) { throw FakturyError("PDF neexistuje: \(p.path)") }

        // the client: an existing one by IČO or name, otherwise a new one
        var client = d.client
        if client.id == 0 {
            if let found = clients().first(where: { (!client.ico.isEmpty && $0.ico == client.ico) || $0.name.caseInsensitiveCompare(client.name) == .orderedSame }) {
                client = found
                if found.email.isEmpty && !d.client.email.isEmpty { client.email = d.client.email; client = try save(client) }
            } else {
                client.source = "import"
                client = try save(client)
            }
        }

        // items: as on the original, or one summary line per document; either way the totals must agree with the PDF
        var items = d.items
        let sub = d.subtotalCents ?? (d.vatMode.chargesVat ? d.totalCents - (d.vatCents ?? 0) : d.totalCents)
        let vat = d.vatCents ?? (d.vatMode.chargesVat ? d.totalCents - sub : 0)
        if items.isEmpty {
            let rate: Double = d.vatMode.chargesVat && sub != 0
                ? [23.0, 20, 19, 10, 5, 0].min(by: { abs($0 - Double(vat) / Double(sub) * 100) < abs($1 - Double(vat) / Double(sub) * 100) })! : 0
            items = [Item(description: "Podľa pôvodnej faktúry č. \(number)", quantity: d.kind == .creditNote ? -1 : 1, unit: "ks",
                          unitPriceCents: abs(sub), vatRate: rate)]
        }
        let computed = Totals.compute(items, mode: d.vatMode)
        if abs(computed.totalCents - d.totalCents) > 2 {
            throw FakturyError("Položky dávajú spolu \(Money.string(computed.totalCents)), na faktúre je \(Money.string(d.totalCents)). Oprav položky alebo ich vynechaj.")
        }

        var i = Invoice()
        i.companyId = company.id
        i.kind = d.kind
        i.client = client
        i.clientId = client.id
        i.issueDate = d.issueDate
        i.deliveryDate = d.deliveryDate ?? d.issueDate
        i.dueDate = d.dueDate ?? d.issueDate
        i.currency = d.currency
        i.vatMode = d.vatMode
        i.items = items
        i.note = d.note
        i.variableSymbol = d.variableSymbol.isEmpty ? String(number.filter(\.isNumber).suffix(10)) : d.variableSymbol.filter(\.isNumber)
        if d.kind == .creditNote {
            i.creditReason = d.creditReason
            if let n = d.creditsNumber { i.creditsInvoiceId = invoice(number: n, companyId: company.id)?.id }
        }
        if d.vatMode == .reverseCharge { i.vatNote = "Prenesenie daňovej povinnosti" }

        // the original PDF, read-only, next to the ones issued here
        var pdfPath: String?, sha: String?
        if let src = d.pdf {
            let year = String(d.issueDate.prefix(4))
            let dir = pdfDir.appendingPathComponent("\(company.id)/\(year)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dst = dir.appendingPathComponent("\(d.kind.filePrefix)-\(number.replacingOccurrences(of: "/", with: "-")).pdf")
            if FileManager.default.fileExists(atPath: dst.path) { dst = dir.appendingPathComponent("\(d.kind.filePrefix)-\(number.replacingOccurrences(of: "/", with: "-"))-import.pdf") }
            try FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dst.path)
            let data = try Data(contentsOf: dst)
            pdfPath = dst.path
            sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        let saved: Invoice = try db.transaction {
            let draft = try saveDraft(i)
            try db.run("""
                UPDATE invoices SET status = 'issued', imported = 1, number = ?, variable_symbol = ?, client_snapshot = ?, supplier_snapshot = ?,
                  subtotal_cents = ?, vat_cents = ?, total_cents = ?, vat_note = ?, pdf_path = ?, pdf_sha256 = ?, issued_at = ?, sent_at = ?, sent_via = 'import',
                  updated_at = ? WHERE id = ? AND status = 'draft'
                """, [number, i.variableSymbol, Store.json(client), Store.json(company), sub, vat, d.totalCents, i.vatNote, pdfPath, sha,
                      d.issueDate, d.issueDate, Day.now, draft.id])
            if d.paidCents != 0 && d.kind != .creditNote {
                try db.run("INSERT INTO payments(invoice_id, date, amount_cents, method, source, note, created_at) VALUES (?,?,?,?,?,?,?)",
                           [draft.id, d.paidDate ?? d.dueDate ?? d.issueDate, d.paidCents, "transfer", "import", "", Day.now])
                try recomputePaid(draft.id)
            }
            let done = invoice(draft.id)!
            try audit("invoice", draft.id, "import", after: Store.json(done))
            return done
        }

        // the series continues after the imported number when it matches the subject's pattern
        let (y, m) = Store.yearMonth(d.issueDate)
        let digits = String(number.reversed().prefix { $0.isNumber }.reversed())
        let seq = (1...max(1, digits.count)).compactMap { k in Int(digits.suffix(k)) }
            .first { Store.format(company.pattern(d.kind), year: y, month: m, n: $0) == number }
        if let n = seq, nextNumber(companyId: company.id, kind: d.kind, year: y) <= n {
            try setNextNumber(companyId: company.id, kind: d.kind, year: y, n + 1)
        }
        if let src = d.pdf, src.path.hasPrefix(Store.importDir.path) {
            try? FileManager.default.createDirectory(at: Store.importDoneDir, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: src, to: Store.importDoneDir.appendingPathComponent(src.lastPathComponent))
        }
        if let p = pdfPath { Backup.mirror(pdf: p, company: company, issueDate: d.issueDate) }
        changed()
        return saved
    }
}
