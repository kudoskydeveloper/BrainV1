import FakturyCore
import Foundation

// faktury-mcp: stdio MCP server (JSON-RPC, one message per line) over the Faktúry database. Works while the app is closed;
// the app picks up changes by itself. Writes are plain MCP write tools, so Brain shows them as proposals; issuing is two steps
// (invoice_issue = preview, commit_issue = issue) and nothing is ever e-mailed from here (invoice_send makes a Courier draft).

setvbuf(stdout, nil, _IOLBF, 0)
let store: Store
do { store = try Store() } catch {
    FileHandle.standardError.write(Data("faktury-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
store.actor = "mcp"

struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write(Data([0x0A]))
}

final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Runs async work (company lookup) from this synchronous loop.
func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached { do { box.value = .success(try await work()) } catch { box.value = .failure(error) }; sem.signal() }
    sem.wait()
    return try box.value!.get()
}

// MARK: JSON shapes

func euros(_ cents: Int) -> Double { Double(cents) / 100 }
func cents(_ v: Any?) -> Int? {
    if let n = v as? NSNumber { return Int((n.doubleValue * 100).rounded(.toNearestOrAwayFromZero)) }
    if let s = v as? String { return Money.parse(s) }
    return nil
}
func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } }

func companyJSON(_ c: Company) -> [String: Any] {
    let year = Int(Day.today.prefix(4))!
    let open = store.invoices(Store.Filter(companyId: c.id, status: .issued)).filter { $0.balanceCents > 0 }
    var next: [String: Any] = [:]
    for k in InvoiceKind.allCases {
        next[k.rawValue] = Store.format(c.pattern(k), year: year, month: Calendar.current.component(.month, from: Date()), n: store.nextNumber(companyId: c.id, kind: k, year: year))
    }
    return ["id": c.id, "name": c.name, "type": c.legalForm == .company ? "firma" : "živnosť", "ico": c.ico, "dic": c.dic, "ic_dph": c.icDph,
            "vat_payer": c.vatPayer, "iban": Validation.formatIBAN(c.iban), "due_days": c.dueDays, "sender_email": c.senderEmail.isEmpty ? c.email : c.senderEmail,
            "street": c.street, "city": c.city, "zip": c.zip, "country": c.country, "registry": c.registry, "swift": c.swift, "bank": c.bankName,
            "email": c.email, "phone": c.phone, "web": c.web, "issued_by": c.issuedBy, "footer_note": c.footerNote, "color": c.color,
            "archived": c.archived, "patterns": ["invoice": c.invoicePattern, "proforma": c.proformaPattern, "credit_note": c.creditPattern],
            "next_numbers": next, "unpaid_count": open.count, "unpaid_total": euros(open.reduce(0) { $0 + $1.balanceCents }),
            "overdue_total": euros(open.filter(\.isOverdue).reduce(0) { $0 + $1.balanceCents })]
}

func clientJSON(_ c: Client) -> [String: Any] {
    var d: [String: Any] = ["name": c.name, "address": c.addressLines.joined(separator: ", "), "country": c.country]
    if c.id != 0 { d["id"] = c.id }
    for (k, v) in [("street", c.street), ("city", c.city), ("zip", c.zip), ("ico", c.ico), ("dic", c.dic), ("ic_dph", c.icDph), ("email", c.email),
                   ("contact_name", c.contactName), ("phone", c.phone), ("note", c.note)] where !v.isEmpty { d[k] = v }
    return d
}

func invoiceRow(_ i: Invoice) -> [String: Any] {
    var d: [String: Any] = ["id": i.id, "kind": i.kind.rawValue, "status": i.status.rawValue, "number": i.number ?? NSNull(),
                            "company": store.company(i.companyId)?.shortName ?? "", "client": i.client.name, "issue_date": i.issueDate, "due_date": i.dueDate,
                            "total": euros(i.totalCents), "currency": i.currency]
    if i.status == .issued && i.kind != .creditNote {
        d["paid"] = i.isPaid
        if i.balanceCents > 0 { d["balance"] = euros(i.balanceCents) }
        if i.isOverdue { d["overdue_days"] = Day.diff(i.dueDate, Day.today) }
        d["sent"] = i.sentAt != nil
    }
    return d
}

func invoiceJSON(_ i: Invoice) -> [String: Any] {
    var d = invoiceRow(i)
    let t = i.totals
    d["company_id"] = i.companyId
    d["client"] = clientJSON(i.client)
    d["delivery_date"] = i.deliveryDate
    d["variable_symbol"] = i.variableSymbol.isEmpty ? (store.previewNumber(i).map { String($0.filter(\.isNumber).suffix(10)) } ?? "") : i.variableSymbol
    d["vat_mode"] = i.vatMode.rawValue
    d["payment_method"] = i.paymentMethod.rawValue
    d["items"] = i.items.map { ["description": $0.description, "quantity": $0.quantity, "unit": $0.unit, "unit_price": euros($0.unitPriceCents),
                                "vat_rate": $0.vatRate, "net": euros($0.netCents)] as [String: Any] }
    d["subtotal"] = euros(t.subtotalCents)
    d["vat"] = euros(t.vatCents)
    d["vat_by_rate"] = t.groups.map { ["rate": $0.rate, "base": euros($0.baseCents), "vat": euros($0.vatCents)] }
    if !i.note.isEmpty { d["note"] = i.note }
    if !i.internalNote.isEmpty { d["internal_note"] = i.internalNote }
    if let n = i.creditsNumber { d["credits_invoice"] = n; d["credit_reason"] = i.creditReason }
    if let p = i.pdfPath { d["pdf"] = p }
    if let s = i.sentAt { d["sent_at"] = s }
    if let p = i.paidAt { d["paid_at"] = p }
    if i.isDraft { d["would_get_number"] = store.previewNumber(i) ?? "" }
    let pays = store.payments(i.id)
    if !pays.isEmpty { d["payments"] = pays.map { ["id": $0.id, "date": $0.date, "amount": euros($0.amountCents), "note": $0.note] } }
    return d
}

// MARK: Resolving

func resolveCompany(_ v: Any?, required: Bool = true) throws -> Company? {
    let all = store.companies()
    if let n = v as? NSNumber, let c = all.first(where: { $0.id == n.int64Value }) { return c }
    if let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
        if let id = Int64(s), let c = all.first(where: { $0.id == id }) { return c }
        let hits = all.filter { $0.name.localizedCaseInsensitiveContains(s) || $0.shortName.localizedCaseInsensitiveCompare(s) == .orderedSame || $0.ico == s }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { throw ToolError("Viac subjektov pasuje na „\(s)“: \(hits.map(\.name).joined(separator: ", ")).") }
        throw ToolError("Subjekt „\(s)“ neexistuje. Subjekty: \(all.map(\.name).joined(separator: ", ")).")
    }
    if all.count == 1 { return all[0] }
    if !required { return nil }
    throw ToolError(all.isEmpty ? "Zatiaľ nie je založený žiadny subjekt (založ ho v appke Faktúry)." : "Ktorý subjekt? \(all.map(\.name).joined(separator: ", ")).")
}

func resolveInvoice(_ a: [String: Any]) throws -> Invoice {
    if let n = a["id"] as? NSNumber, let i = store.invoice(n.int64Value) { return i }
    if let s = a["number"] as? String, let i = store.invoice(number: s) { return i }
    if let s = a["id"] as? String, let n = Int64(s), let i = store.invoice(n) { return i }
    throw ToolError("Doklad nenájdený (id alebo number).")
}

func clientFrom(_ d: [String: Any], base: Client = Client()) -> Client {
    var c = base
    func s(_ k: String) -> String? { (d[k] as? String)?.trimmingCharacters(in: .whitespaces) }
    if let v = s("name") { c.name = v }
    if let v = s("street") { c.street = v }
    if let v = s("city") { c.city = v }
    if let v = s("zip") { c.zip = v }
    if let v = s("country") { c.country = v.uppercased() }
    if let v = s("ico") { c.ico = v.filter(\.isNumber) }
    if let v = s("dic") { c.dic = v }
    if let v = s("ic_dph") { c.icDph = v.uppercased().replacingOccurrences(of: " ", with: "") }
    if let v = s("email") { c.email = v }
    if let v = s("contact_name") { c.contactName = v }
    if let v = s("phone") { c.phone = v }
    if let v = s("note") { c.note = v }
    return c
}

/// client_id, a client object (matched by IČO or name, saved), client_query (existing), or ico (looked up in the register).
func resolveClient(_ a: [String: Any]) throws -> Client? {
    if let n = a["client_id"] as? NSNumber { guard let c = store.client(n.int64Value) else { throw ToolError("Odberateľ \(n) neexistuje.") }; return c }
    if let d = a["client"] as? [String: Any] {
        let ico = (d["ico"] as? String)?.filter(\.isNumber) ?? ""
        let name = d["name"] as? String ?? ""
        let existing = store.clients().first { (!ico.isEmpty && $0.ico == ico) || (!name.isEmpty && $0.name.caseInsensitiveCompare(name) == .orderedSame) }
        var c = clientFrom(d, base: existing ?? Client())
        if c.street.isEmpty, !ico.isEmpty, let found = try? wait({ try await CompanyLookup.byICO(ico) }) {
            var f = clientFrom(d, base: found); f.id = c.id; c = f
        }
        return try store.save(c)
    }
    if let q = a["client_query"] as? String {
        let hits = store.searchClients(q)
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { throw ToolError("Odberateľ „\(q)“ nenájdený. Pošli client s údajmi (stačí ico) alebo použi company_lookup.") }
        if let exact = hits.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return exact }
        throw ToolError("Viac odberateľov pasuje: \(hits.prefix(8).map { "\($0.name) (id \($0.id))" }.joined(separator: ", ")).")
    }
    if let ico = a["ico"] as? String {
        if let c = store.clients().first(where: { $0.ico == ico.filter(\.isNumber) }) { return c }
        guard let found = try wait({ try await CompanyLookup.find(ico) }) else { throw ToolError("IČO \(ico) sa v registri nenašlo.") }
        return try store.save(found)
    }
    return nil
}

func items(_ v: Any?, defaultRate: Double) throws -> [Item]? {
    guard let list = v as? [[String: Any]] else { return nil }
    return try list.map { d in
        guard let desc = d["description"] as? String, !desc.isEmpty else { throw ToolError("Každá položka potrebuje description.") }
        guard let price = cents(d["unit_price"]) else { throw ToolError("Položka „\(desc)“: chýba unit_price (v eurách bez DPH).") }
        return Item(description: desc, quantity: double(d["quantity"]) ?? 1, unit: d["unit"] as? String ?? "ks", unitPriceCents: price,
                    vatRate: double(d["vat_rate"]) ?? defaultRate)
    }
}

// MARK: Tools

let readOnly: Set<String> = ["accounts", "contacts", "company_lookup", "invoice_list", "invoice_get", "stats", "invoice_issue", "audit_log", "open_in_app", "import_pending", "template_list"]

let itemSchema: [String: Any] = ["type": "object", "properties": [
    "description": ["type": "string"], "quantity": ["type": "number"], "unit": ["type": "string", "description": "ks, hod, deň, mes, paušál…"],
    "unit_price": ["type": "number", "description": "cena za jednotku v eurách bez DPH"], "vat_rate": ["type": "number", "description": "23, 19, 5 alebo 0"]],
    "required": ["description", "unit_price"]]
let clientSchema: [String: Any] = ["type": "object", "description": "odberateľ; stačí ico (zvyšok sa doplní z registra) alebo name + adresa",
    "properties": ["name": ["type": "string"], "street": ["type": "string"], "city": ["type": "string"], "zip": ["type": "string"],
                   "country": ["type": "string", "description": "ISO kód, predvolene SK"], "ico": ["type": "string"], "dic": ["type": "string"],
                   "ic_dph": ["type": "string"], "email": ["type": "string", "description": "e-mail na faktúry"], "contact_name": ["type": "string"], "phone": ["type": "string"]]]

let toolDefs: [[String: Any]] = [
    ["name": "accounts", "description": "Moje subjekty (firmy a živnosti), ktoré vystavujú faktúry: údaje, platiteľ DPH, ďalšie čísla v radoch, neuhradené a po splatnosti.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "contacts", "description": "Odberatelia uložení vo Faktúrach (hľadá v názve, IČO, DIČ, e-maile).",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]]]],
    ["name": "company_lookup", "description": "Dohľadá firmu v registri: IČO (SK, názov, adresa, DIČ, IČ DPH) alebo IČ DPH z EÚ (VIES). Nič neukladá.",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "IČO alebo IČ DPH s kódom krajiny"]], "required": ["query"]]],
    ["name": "invoice_list", "description": "Doklady (faktúry, zálohové, dobropisy), najnovšie prvé. status: draft (koncepty), issued, unpaid (neuhradené), overdue (po splatnosti), all.",
     "inputSchema": ["type": "object", "properties": [
        "company": ["type": "string", "description": "názov alebo id subjektu"], "status": ["type": "string", "enum": ["draft", "issued", "unpaid", "overdue", "all"]],
        "client": ["type": "string", "description": "názov alebo IČO odberateľa"], "from": ["type": "string", "description": "dátum vystavenia od (YYYY-MM-DD)"],
        "to": ["type": "string"], "query": ["type": "string"], "limit": ["type": "integer", "description": "predvolene 50"]]]],
    ["name": "invoice_get", "description": "Celý doklad: odberateľ, položky, DPH, úhrady, cesta k PDF.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"]]]],
    ["name": "stats", "description": "Príjmy podľa mesiacov (vystavené faktúry mínus dobropisy, bez zálohových) a neuhradené.",
     "inputSchema": ["type": "object", "properties": ["company": ["type": "string"], "year": ["type": "integer"]]]],
    ["name": "invoice_draft", "description": "Vytvorí alebo upraví KONCEPT dokladu (nič nevystaví, číslo sa nepridelí). Bez id nový koncept. Ceny v eurách bez DPH. Odberateľ: client_id, client (objekt), client_query (existujúci) alebo ico (z registra). Po kontrole s používateľom vystav cez invoice_issue → commit_issue.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "integer", "description": "id existujúceho konceptu na úpravu"], "company": ["type": "string"],
        "kind": ["type": "string", "enum": ["invoice", "proforma"], "description": "predvolene invoice"],
        "client_id": ["type": "integer"], "client": clientSchema, "client_query": ["type": "string"], "ico": ["type": "string"],
        "items": ["type": "array", "items": itemSchema, "description": "nahradí všetky položky"],
        "issue_date": ["type": "string"], "delivery_date": ["type": "string"], "due_date": ["type": "string"], "due_days": ["type": "integer"],
        "vat_mode": ["type": "string", "enum": ["standard", "non_payer", "reverse_charge"]], "payment_method": ["type": "string", "enum": ["transfer", "cash", "card"]],
        "variable_symbol": ["type": "string"], "note": ["type": "string", "description": "poznámka na faktúre"], "internal_note": ["type": "string"]]]],
    ["name": "invoice_issue", "description": "Krok 1 vystavenia: kontrola náležitostí a náhľad (subjekt, odberateľ, položky, suma, číslo, ktoré dostane). Nič nemení. Ukáž to používateľovi; po jeho áno zavolaj commit_issue.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "commit_issue", "description": "Krok 2: vystaví koncept (pridelí číslo, uloží nemenné PDF s QR PAY by square). Len po súhlase používateľa s náhľadom z invoice_issue.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "invoice_credit", "description": "Koncept dobropisu k vystavenej faktúre (rovnaké položky so zápornými množstvami, alebo vlastné items pre čiastočný). Vystaví sa cez invoice_issue → commit_issue.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer", "description": "id pôvodnej faktúry"], "number": ["type": "string"],
                                                       "reason": ["type": "string", "description": "dôvod opravy (povinný)"], "items": ["type": "array", "items": itemSchema]],
                     "required": ["reason"]]],
    ["name": "invoice_delete", "description": "Zmaže vystavený doklad: len posledný v rade, neodoslaný a neuhradený (rad sa vráti o číslo späť), alebo importovaný záznam. Inak treba dobropis. Len po výslovnom súhlase používateľa.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"]]]],
    ["name": "invoice_delete_draft", "description": "Zmaže koncept (vystavené doklady sa zmazať nedajú).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "invoice_send", "description": "Pripraví e-mail s PDF ako KONCEPT v Courieri (na e-mail odberateľa, z účtu subjektu). Neodosiela; používateľ ho odošle v Courieri, potom invoice_mark_sent.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"], "to": ["type": "string"], "body": ["type": "string"]]]],
    ["name": "invoice_mark_sent", "description": "Označí doklad ako odoslaný odberateľovi.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"], "date": ["type": "string"]]]],
    ["name": "invoice_mark_paid", "description": "Zapíše úhradu faktúry (bez amount celý zostatok).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"], "amount": ["type": "number", "description": "v eurách"],
                                                       "date": ["type": "string"], "note": ["type": "string"]]]],
    ["name": "contact_upsert", "description": "Uloží odberateľa (nového alebo podľa id). S ico a bez adresy doplní údaje z registra.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "client": clientSchema], "required": ["client"]]],
    ["name": "company_upsert", "description": "Založí alebo upraví môj subjekt (firma alebo živnosť): údaje, DPH, banka, kontakt, splatnosť, vzory číselných radov a ďalšie čísla. Bez id nový subjekt; s ico a bez adresy doplní údaje z registra.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "integer"], "type": ["type": "string", "enum": ["firma", "živnosť"]], "name": ["type": "string"], "street": ["type": "string"],
        "city": ["type": "string"], "zip": ["type": "string"], "country": ["type": "string"], "ico": ["type": "string"], "dic": ["type": "string"],
        "ic_dph": ["type": "string"], "vat_payer": ["type": "boolean"], "registry": ["type": "string", "description": "údaj o zápise v OR / živnostenskom registri"],
        "iban": ["type": "string"], "swift": ["type": "string"], "bank": ["type": "string"], "email": ["type": "string"], "phone": ["type": "string"],
        "web": ["type": "string"], "sender_email": ["type": "string", "description": "účet v Courieri, z ktorého idú faktúry"], "due_days": ["type": "integer"],
        "issued_by": ["type": "string"], "footer_note": ["type": "string"], "color": ["type": "string"], "archived": ["type": "boolean"],
        "patterns": ["type": "object", "description": "{invoice, proforma, credit_note}: vzor ako {YYYY}{NNNN}"],
        "next_numbers": ["type": "object", "description": "{invoice, proforma, credit_note}: ďalšie poradové číslo v tomto roku (celé číslo)"]]]],
    ["name": "contact_delete", "description": "Zmaže odberateľa (len ak nemá vystavené doklady).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "payment_delete", "description": "Zmaže zapísanú úhradu (id z invoice_get → payments).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "invoice_note", "description": "Interná poznámka k dokladu (netlačí sa; dá sa meniť aj pri vystavenom).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"], "note": ["type": "string"]], "required": ["note"]]],
    ["name": "invoice_duplicate", "description": "Nový koncept s rovnakým odberateľom a položkami (dátumy od dnes).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"]]]],
    ["name": "invoice_from_proforma", "description": "Koncept ostrej faktúry z vystavenej zálohovej (rovnaké položky, odkaz na zálohu).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"]]]],
    ["name": "proforma_cancel", "description": "Zruší vystavenú zálohovú faktúru (číslo ostane použité).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"]]]],
    ["name": "audit_log", "description": "História zmien (kto, kedy, čo): celý log alebo k jednému dokladu / odberateľovi / subjektu.",
     "inputSchema": ["type": "object", "properties": ["entity": ["type": "string", "enum": ["invoice", "client", "company", "payment", "number_series", "backup", "export"]],
                                                       "id": ["type": "integer"], "limit": ["type": "integer"]]]],
    ["name": "backup_now", "description": "Okamžitá záloha databázy do iCloud Drive › Faktúry.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "open_in_app", "description": "Otvorí doklad (alebo zoznam unpaid/overdue/drafts/new) v appke Faktúry.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "number": ["type": "string"], "view": ["type": "string", "enum": ["unpaid", "overdue", "drafts", "new", "overview", "clients"]]]]],
    ["name": "import_pending", "description": "PDF staré faktúry čakajúce na import (iCloud Drive › Faktúry › Import) s ich textom. Z textu vyčítaj údaje, ukáž používateľovi tabuľku (číslo, dátumy, odberateľ, základ, DPH, spolu, uhradená) a po jeho áno ich ulož cez invoice_import.",
     "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer"]]]],
    ["name": "invoice_import", "description": "Uloží starú (už vystavenú) faktúru ako archívny záznam s jej pôvodným PDF: nič sa neprekresľuje ani neprečísluje, započíta sa do prehľadu, neuhradených a odberateľov. Položky nepovinné (bez nich jeden súhrnný riadok); súčet musí sedieť s total. Rad pokračuje za importovaným číslom, ak zodpovedá vzoru subjektu. PDF z priečinka Import sa presunie do Import/Hotové.",
     "inputSchema": ["type": "object", "properties": [
        "company": ["type": "string"], "pdf": ["type": "string", "description": "cesta k PDF (z import_pending)"],
        "kind": ["type": "string", "enum": ["invoice", "proforma", "credit_note"]], "number": ["type": "string"],
        "issue_date": ["type": "string"], "delivery_date": ["type": "string"], "due_date": ["type": "string"],
        "client_id": ["type": "integer"], "client": clientSchema, "ico": ["type": "string"],
        "items": ["type": "array", "items": itemSchema], "vat_mode": ["type": "string", "enum": ["standard", "non_payer", "reverse_charge"]],
        "subtotal": ["type": "number", "description": "základ bez DPH v eurách"], "vat": ["type": "number"], "total": ["type": "number", "description": "spolu na úhradu v eurách"],
        "currency": ["type": "string"], "variable_symbol": ["type": "string"],
        "paid": ["type": "boolean", "description": "celá uhradená"], "paid_amount": ["type": "number"], "paid_date": ["type": "string"],
        "note": ["type": "string"], "credits_number": ["type": "string", "description": "pri dobropise číslo pôvodnej faktúry"], "credit_reason": ["type": "string"]],
     "required": ["number", "issue_date", "total"]]],
    ["name": "template_list", "description": "Šablóny opakovaných faktúr (odberateľ, položky, splatnosť) podľa subjektov.",
     "inputSchema": ["type": "object", "properties": ["company": ["type": "string"]]]],
    ["name": "invoice_from_template", "description": "Nový koncept zo šablóny (dátumy od dnes). Potom prípadne invoice_draft na úpravu a invoice_issue → commit_issue.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"], "name": ["type": "string", "description": "názov šablóny (ak nie id)"]]]],
    ["name": "template_save", "description": "Uloží doklad (koncept alebo vystavený) ako šablónu s názvom; rovnaký názov v subjekte sa prepíše.",
     "inputSchema": ["type": "object", "properties": ["invoice_id": ["type": "integer"], "number": ["type": "string"], "name": ["type": "string"]], "required": ["name"]]],
    ["name": "template_delete", "description": "Zmaže šablónu (faktúry z nej ostanú).",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]]],
    ["name": "export_accountant", "description": "Export pre účtovníčku za mesiac: priečinok s PDF a CSV prehľadom (DPH podľa sadzieb) v ~/Downloads.",
     "inputSchema": ["type": "object", "properties": ["company": ["type": "string"], "month": ["type": "string", "description": "YYYY-MM"]], "required": ["month"]]],
]

let tools: [[String: Any]] = toolDefs.map { t in
    var t = t
    if readOnly.contains(t["name"] as! String) { t["annotations"] = ["readOnlyHint": true] }
    return t
}

func call(_ name: String, _ a: [String: Any]) throws -> Any {
    let limit = (a["limit"] as? NSNumber)?.intValue
    switch name {
    case "accounts":
        return store.companies().map(companyJSON)
    case "contacts":
        return store.searchClients(a["query"] as? String ?? "", limit: limit ?? 30).map(clientJSON)
    case "company_lookup":
        let q = a["query"] as? String ?? ""
        guard let c = try wait({ try await CompanyLookup.find(q) }) else { return ["found": false] }
        var d = clientJSON(c); d["found"] = true
        if let existing = store.clients().first(where: { !c.ico.isEmpty && $0.ico == c.ico }) { d["saved_as_id"] = existing.id }
        return d
    case "invoice_list":
        var f = Store.Filter(companyId: try resolveCompany(a["company"], required: false)?.id)
        switch a["status"] as? String ?? "all" {
        case "draft": f.status = .draft
        case "issued": f.status = .issued
        case "unpaid": f.unpaid = true
        case "overdue": f.overdue = true
        default: break
        }
        f.from = a["from"] as? String; f.to = a["to"] as? String; f.query = a["query"] as? String
        var list = store.invoices(f)
        if let c = a["client"] as? String, !c.isEmpty { list = list.filter { $0.client.name.localizedCaseInsensitiveContains(c) || $0.client.ico == c } }
        return list.prefix(limit ?? 50).map(invoiceRow)
    case "invoice_get":
        return invoiceJSON(try resolveInvoice(a))
    case "stats":
        let c = try resolveCompany(a["company"], required: false)
        let year = (a["year"] as? NSNumber)?.intValue ?? Int(Day.today.prefix(4))!
        let months = store.monthly(companyId: c?.id, year: year)
        let open = store.invoices(Store.Filter(companyId: c?.id, status: .issued)).filter { $0.balanceCents > 0 }
        return ["company": c?.name ?? "všetky", "year": year,
                "months": months.map { ["month": $0.month, "net": euros($0.netCents), "total": euros($0.totalCents), "count": $0.count] },
                "year_net": euros(months.reduce(0) { $0 + $1.netCents }), "year_total": euros(months.reduce(0) { $0 + $1.totalCents }),
                "unpaid_total": euros(open.reduce(0) { $0 + $1.balanceCents }), "overdue": open.filter(\.isOverdue).map(invoiceRow)]
    case "invoice_draft":
        var inv: Invoice
        if let id = (a["id"] as? NSNumber)?.int64Value {
            guard let i = store.invoice(id) else { throw ToolError("Koncept \(id) neexistuje.") }
            guard i.isDraft else { throw ToolError("\(i.title) je vystavený, meniť sa nedá (oprava dobropisom: invoice_credit).") }
            inv = i
        } else {
            guard let c = try resolveCompany(a["company"]) else { throw ToolError("Chýba company.") }
            inv = try store.newDraft(companyId: c.id, kind: InvoiceKind(rawValue: a["kind"] as? String ?? "") ?? .invoice)
        }
        guard let company = store.company(inv.companyId) else { throw ToolError("Subjekt neexistuje.") }
        if let k = a["kind"] as? String, let kind = InvoiceKind(rawValue: k), kind != .creditNote { inv.kind = kind }
        if let cl = try resolveClient(a) { inv.client = cl; inv.clientId = cl.id; store.applyClientDefaults(&inv, company: company) }
        if let it = try items(a["items"], defaultRate: company.vatPayer ? 23 : 0) { inv.items = it }
        if let d = a["issue_date"] as? String { inv.issueDate = d; if a["delivery_date"] == nil { inv.deliveryDate = d } }
        if let d = a["delivery_date"] as? String { inv.deliveryDate = d }
        if let d = a["due_date"] as? String { inv.dueDate = d }
        else if let n = (a["due_days"] as? NSNumber)?.intValue { inv.dueDate = Day.adding(n, to: inv.issueDate) }
        else if a["issue_date"] != nil { inv.dueDate = Day.adding(company.dueDays, to: inv.issueDate) }
        if let m = a["vat_mode"] as? String, let v = VatMode(rawValue: m) { inv.vatMode = v }
        if let m = a["payment_method"] as? String, let v = PaymentMethod(rawValue: m) { inv.paymentMethod = v }
        if let v = a["variable_symbol"] as? String { inv.variableSymbol = v.filter(\.isNumber) }
        if let v = a["note"] as? String { inv.note = v }
        if let v = a["internal_note"] as? String { inv.internalNote = v }
        inv = try store.saveDraft(inv)
        var d = invoiceJSON(inv)
        let ch = store.check(inv)
        if !ch.errors.isEmpty { d["missing"] = ch.errors }
        if !ch.warnings.isEmpty { d["warnings"] = ch.warnings }
        d["next"] = "Koncept uložený (aj v appke Faktúry). Na vystavenie: invoice_issue (náhľad), potom commit_issue po súhlase."
        return d
    case "invoice_issue":
        let inv = try resolveInvoice(a)
        guard inv.isDraft else { throw ToolError("\(inv.title) už je vystavený.") }
        let ch = store.check(inv)
        var d = invoiceJSON(inv)
        d["supplier"] = store.company(inv.companyId).map(companyJSON) ?? [:]
        d["number_on_issue"] = store.previewNumber(inv) ?? ""
        d["ready"] = ch.ok
        if !ch.errors.isEmpty { d["errors"] = ch.errors }
        if !ch.warnings.isEmpty { d["warnings"] = ch.warnings }
        d["next"] = ch.ok ? "Ukáž používateľovi súhrn (subjekt, odberateľ, položky, suma, číslo). Až po jeho áno zavolaj commit_issue s id \(inv.id). Vystavený doklad sa už nedá zmeniť."
                          : "Najprv oprav chyby (invoice_draft alebo v appke)."
        return d
    case "commit_issue":
        let inv = try resolveInvoice(a)
        let issued = try MainActor.assumeIsolated { try store.issue(inv.id) }
        var d = invoiceJSON(issued)
        d["next"] = "Vystavené. PDF: \(issued.pdfPath ?? ""). Poslať: invoice_send (koncept v Courieri)."
        return d
    case "invoice_credit":
        let src = try resolveInvoice(a)
        var cn = try store.creditNoteDraft(for: src.id, reason: a["reason"] as? String ?? "")
        if let it = try items(a["items"], defaultRate: src.vatMode.chargesVat ? 23 : 0) {
            cn.items = it.map { var x = $0; x.quantity = -abs(x.quantity); return x }
            cn = try store.saveDraft(cn)
        }
        var d = invoiceJSON(cn)
        d["next"] = "Koncept dobropisu. Vystavenie: invoice_issue → commit_issue."
        return d
    case "invoice_delete":
        let inv = try resolveInvoice(a)
        try store.deleteDocument(inv.id)
        return ["deleted": true, "id": inv.id, "number": inv.number ?? ""] as [String: Any]
    case "invoice_delete_draft":
        let inv = try resolveInvoice(a)
        try store.deleteDraft(inv.id)
        return ["deleted": true, "id": inv.id]
    case "invoice_send":
        let inv = try resolveInvoice(a)
        guard let c = store.company(inv.companyId) else { throw ToolError("Subjekt neexistuje.") }
        let preview = try CourierBridge.draft(inv, company: c, to: a["to"] as? String, body: a["body"] as? String)
        return ["courier_draft": true, "courier": preview,
                "next": "E-mail je v Courieri v Konceptoch. Používateľ ho odošle; potom invoice_mark_sent."]
    case "invoice_mark_sent":
        let inv = try resolveInvoice(a)
        try store.markSent(inv.id, via: "courier", at: (a["date"] as? String) ?? Day.now)
        return invoiceRow(store.invoice(inv.id) ?? inv)
    case "invoice_mark_paid":
        let inv = try resolveInvoice(a)
        let updated = try store.addPayment(inv.id, amountCents: cents(a["amount"]), date: (a["date"] as? String) ?? Day.today, source: "mcp", note: a["note"] as? String ?? "")
        return invoiceRow(updated)
    case "contact_upsert":
        guard let d = a["client"] as? [String: Any] else { throw ToolError("Chýba client.") }
        var base = Client()
        if let id = (a["id"] as? NSNumber)?.int64Value { guard let c = store.client(id) else { throw ToolError("Odberateľ \(id) neexistuje.") }; base = c }
        var c = clientFrom(d, base: base)
        let ico = c.ico
        if c.street.isEmpty, !ico.isEmpty, let found = try? wait({ try await CompanyLookup.byICO(ico) }) { var f = clientFrom(d, base: found); f.id = c.id; c = f }
        return clientJSON(try store.save(c))
    case "company_upsert":
        var c = Company()
        if let id = (a["id"] as? NSNumber)?.int64Value { guard let e = store.company(id) else { throw ToolError("Subjekt \(id) neexistuje.") }; c = e }
        func s(_ k: String) -> String? { (a[k] as? String)?.trimmingCharacters(in: .whitespaces) }
        if let t = s("type") { c.legalForm = t.lowercased().hasPrefix("ž") || t.lowercased().hasPrefix("z") ? .soleTrader : .company }
        if let v = s("ico") { c.ico = v.filter(\.isNumber) }
        if c.id == 0 && c.street.isEmpty && s("street") == nil && !c.ico.isEmpty, let found = try? wait({ [ico = c.ico] in try await CompanyLookup.byICO(ico) }) {
            c.name = found.name; c.street = found.street; c.city = found.city; c.zip = found.zip; c.dic = found.dic
            if !found.icDph.isEmpty { c.icDph = found.icDph; c.vatPayer = true }
        }
        if let v = s("name") { c.name = v }
        if let v = s("street") { c.street = v }
        if let v = s("city") { c.city = v }
        if let v = s("zip") { c.zip = v }
        if let v = s("country") { c.country = v.uppercased() }
        if let v = s("dic") { c.dic = v }
        if let v = s("ic_dph") { c.icDph = v.uppercased().replacingOccurrences(of: " ", with: "") }
        if let v = a["vat_payer"] as? Bool { c.vatPayer = v }
        if let v = s("registry") { c.registry = v }
        if let v = s("iban") { c.iban = v }
        if let v = s("swift") { c.swift = v.uppercased() }
        if let v = s("bank") { c.bankName = v }
        if let v = s("email") { c.email = v }
        if let v = s("phone") { c.phone = v }
        if let v = s("web") { c.web = v }
        if let v = s("sender_email") { c.senderEmail = v }
        if let v = (a["due_days"] as? NSNumber)?.intValue { c.dueDays = v }
        if let v = s("issued_by") { c.issuedBy = v }
        if let v = s("footer_note") { c.footerNote = v }
        if let v = s("color"), Palette.names.contains(v) { c.color = v }
        if let v = a["archived"] as? Bool { c.archived = v }
        if let p = a["patterns"] as? [String: Any] {
            if let v = p["invoice"] as? String { c.invoicePattern = v }
            if let v = p["proforma"] as? String { c.proformaPattern = v }
            if let v = p["credit_note"] as? String { c.creditPattern = v }
        }
        if !c.iban.isEmpty && !Validation.iban(c.iban) { throw ToolError("IBAN \(c.iban) nie je platný.") }
        let saved = try store.save(c)
        if let n = a["next_numbers"] as? [String: Any] {
            let year = Int(Day.today.prefix(4))!
            for (k, v) in n {
                guard let kind = InvoiceKind(rawValue: k), let num = (v as? NSNumber)?.intValue ?? (v as? String).flatMap({ Int($0) }) else { continue }
                try store.setNextNumber(companyId: saved.id, kind: kind, year: year, num)
            }
        }
        return companyJSON(store.company(saved.id) ?? saved)
    case "contact_delete":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError("Chýba id.") }
        try store.deleteClient(id)
        return ["deleted": true, "id": id]
    case "payment_delete":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError("Chýba id.") }
        try store.deletePayment(id)
        return ["deleted": true, "id": id]
    case "invoice_note":
        let inv = try resolveInvoice(a)
        try store.setNotes(inv.id, internalNote: a["note"] as? String ?? "")
        return invoiceRow(store.invoice(inv.id) ?? inv)
    case "invoice_duplicate":
        return invoiceJSON(try store.duplicate(try resolveInvoice(a).id))
    case "invoice_from_proforma":
        return invoiceJSON(try store.invoiceFromProforma(try resolveInvoice(a).id))
    case "proforma_cancel":
        let inv = try resolveInvoice(a)
        try store.cancelProforma(inv.id)
        return invoiceRow(store.invoice(inv.id) ?? inv)
    case "audit_log":
        return store.auditLog(entity: a["entity"] as? String, id: (a["id"] as? NSNumber)?.int64Value, limit: limit ?? 50).map {
            ["at": $0.at, "actor": $0.actor, "entity": $0.entity, "id": $0.entityId ?? NSNull(), "action": $0.action] as [String: Any]
        }
    case "backup_now":
        return ["backup": try Backup.run(store, reason: "manual").path]
    case "open_in_app":
        var url = "faktury://\(a["view"] as? String ?? "unpaid")"
        if a["id"] != nil || a["number"] != nil { url = "faktury://invoice/\(try resolveInvoice(a).id)" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url]; try p.run(); p.waitUntilExit()
        return ["opened": url]
    case "import_pending":
        let list = store.pendingImports(limit: limit ?? 20)
        return ["folder": Store.importDir.path, "count": list.count,
                "pdfs": list.map { ["file": $0.url.lastPathComponent, "pdf": $0.url.path, "text": String($0.text.prefix(6000))] }]
    case "invoice_import":
        guard let c = try resolveCompany(a["company"]) else { throw ToolError("Chýba company.") }
        var client = Client()
        if let cl = try resolveClient(a) { client = cl }
        guard let total = cents(a["total"]) else { throw ToolError("Chýba total.") }
        let kind = InvoiceKind(rawValue: a["kind"] as? String ?? "") ?? .invoice
        let mode = VatMode(rawValue: a["vat_mode"] as? String ?? "") ?? (c.vatPayer ? .standard : .nonPayer)
        var d = ImportedInvoice(companyId: c.id, number: a["number"] as? String ?? "", issueDate: a["issue_date"] as? String ?? "",
                                client: client, vatMode: mode, totalCents: total)
        d.kind = kind
        d.deliveryDate = a["delivery_date"] as? String
        d.dueDate = a["due_date"] as? String
        d.items = try items(a["items"], defaultRate: mode.chargesVat ? 23 : 0) ?? []
        d.subtotalCents = cents(a["subtotal"])
        d.vatCents = cents(a["vat"])
        d.currency = a["currency"] as? String ?? "EUR"
        d.variableSymbol = a["variable_symbol"] as? String ?? ""
        if a["paid"] as? Bool == true { d.paidCents = total } else if let p = cents(a["paid_amount"]) { d.paidCents = p }
        d.paidDate = a["paid_date"] as? String
        d.note = a["note"] as? String ?? ""
        d.creditsNumber = a["credits_number"] as? String
        d.creditReason = a["credit_reason"] as? String ?? ""
        if let p = a["pdf"] as? String, !p.isEmpty { d.pdf = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        let inv = try store.importInvoice(d)
        var out = invoiceRow(inv)
        out["imported"] = true
        out["next_number"] = Store.format(c.pattern(kind), year: Int(Day.today.prefix(4))!, month: Calendar.current.component(.month, from: Date()),
                                          n: store.nextNumber(companyId: c.id, kind: kind, year: Int(Day.today.prefix(4))!))
        return out
    case "template_list":
        let c = try resolveCompany(a["company"], required: false)
        return store.templates(companyId: c?.id).map { t -> [String: Any] in
            ["id": t.id, "name": t.name, "company": store.company(t.companyId)?.shortName ?? "", "kind": t.kind.rawValue, "client": t.client.name,
             "items": t.items.map { ["description": $0.description, "quantity": $0.quantity, "unit": $0.unit, "unit_price": euros($0.unitPriceCents)] as [String: Any] },
             "total": euros(t.totalCents), "due_days": t.dueDays ?? NSNull()]
        }
    case "invoice_from_template":
        var tid = (a["id"] as? NSNumber)?.int64Value
        if tid == nil, let n = a["name"] as? String {
            let hits = store.templates().filter { $0.name.localizedCaseInsensitiveContains(n) }
            guard hits.count == 1 else { throw ToolError(hits.isEmpty ? "Šablóna „\(n)“ neexistuje." : "Viac šablón pasuje: \(hits.map(\.name).joined(separator: ", ")).") }
            tid = hits[0].id
        }
        guard let id = tid else { throw ToolError("Chýba id alebo name šablóny.") }
        var d = invoiceJSON(try store.draft(fromTemplate: id))
        d["next"] = "Koncept zo šablóny. Uprav cez invoice_draft (napr. množstvá), vystav cez invoice_issue → commit_issue."
        return d
    case "template_save":
        var src = a
        if let n = a["invoice_id"] { src["id"] = n }
        let inv = try resolveInvoice(src)
        let t = try store.saveTemplate(from: inv.id, name: a["name"] as? String ?? "")
        return ["id": t.id, "name": t.name, "total": euros(t.totalCents)]
    case "template_delete":
        guard let id = (a["id"] as? NSNumber)?.int64Value else { throw ToolError("Chýba id.") }
        try store.deleteTemplate(id)
        return ["deleted": true, "id": id]
    case "export_accountant":
        guard let c = try resolveCompany(a["company"]) else { throw ToolError("Chýba company.") }
        let month = a["month"] as? String ?? String(Day.today.prefix(7))
        let dir = try AccountantExport.export(store, companyId: c.id, month: month,
                                              to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        return ["folder": dir.path]
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
            "serverInfo": ["name": "faktury", "version": "0.1"],
            "instructions": "Faktúry sú lokálna fakturačná appka používateľa (viac subjektov: firmy a živnosti). accounts = subjekty (company_upsert ich zakladá a upravuje vrátane číselných radov), contacts = odberatelia, invoice_list (status unpaid/overdue) a invoice_get na čítanie, stats na príjmy. Opakované faktúry: template_list a invoice_from_template. Nová faktúra: invoice_draft (koncept; odberateľ podľa IČO sa doplní z registra) → invoice_issue (náhľad a kontrola) → po súhlase commit_issue. Vystavený doklad sa nedá meniť, oprava len dobropisom (invoice_credit). Poslanie: invoice_send pripraví koncept e-mailu s PDF v Courieri, nikdy neodosiela. Úhrada: invoice_mark_paid. Sumy sú v eurách, ceny položiek bez DPH.",
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
