import Foundation

/// Kind of subject: a company in the business register, or a sole trader (živnosť) in the trade register.
public enum LegalForm: String, Codable, CaseIterable, Hashable {
    case company, soleTrader = "sole_trader"
    public var label: String { self == .company ? "Firma (s.r.o., a.s.)" : "Živnosť" }
    public var registryPlaceholder: String {
        self == .company ? "Zapísaná v Obchodnom registri Mestského súdu Bratislava III, oddiel Sro, vložka č. …"
                         : "Zapísaný v Živnostenskom registri Okresného úradu …, č. živ. registra …"
    }
}

/// One of my own subjects that issues invoices.
public struct Company: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var name = ""
    public var legalForm: LegalForm = .company
    public var street = "", city = "", zip = "", country = "SK"
    public var ico = "", dic = "", icDph = ""
    public var vatPayer = false
    public var registry = ""
    public var iban = "", swift = "", bankName = ""
    public var email = "", phone = "", web = ""
    /// Courier account the invoices go out from.
    public var senderEmail = ""
    public var dueDays = 14
    public var issuedBy = ""
    public var footerNote = ""
    public var color = "blue"
    public var logoPath = ""
    public var invoicePattern = "{YYYY}{NNNN}"
    public var creditPattern = "D{YYYY}{NNN}"
    public var proformaPattern = "Z{YYYY}{NNN}"
    public var archived = false
    public init() {}

    public var shortName: String {
        var n = name
        for suffix in [", s.r.o.", " s.r.o.", ", a.s.", " a.s.", " s. r. o.", ", s. r. o."] where n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)) }
        return n
    }
    public func pattern(_ k: InvoiceKind) -> String {
        switch k { case .invoice: invoicePattern; case .creditNote: creditPattern; case .proforma: proformaPattern }
    }
    public var addressLines: [String] { [street, [zip, city].filter { !$0.isEmpty }.joined(separator: " "), country == "SK" ? "" : Country.name(country)].filter { !$0.isEmpty } }

    enum CodingKeys: String, CodingKey {
        case id, name, legalForm, street, city, zip, country, ico, dic, icDph, vatPayer, registry, iban, swift, bankName, email, phone, web,
             senderEmail, dueDays, issuedBy, footerNote, color, logoPath, invoicePattern, creditPattern, proformaPattern, archived
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        name = s(.name); legalForm = (try? c.decode(LegalForm.self, forKey: .legalForm)) ?? .company
        street = s(.street); city = s(.city); zip = s(.zip); country = s(.country).isEmpty ? "SK" : s(.country)
        ico = s(.ico); dic = s(.dic); icDph = s(.icDph); vatPayer = (try? c.decode(Bool.self, forKey: .vatPayer)) ?? false
        registry = s(.registry); iban = s(.iban); swift = s(.swift); bankName = s(.bankName)
        email = s(.email); phone = s(.phone); web = s(.web); senderEmail = s(.senderEmail)
        dueDays = (try? c.decode(Int.self, forKey: .dueDays)) ?? 14
        issuedBy = s(.issuedBy); footerNote = s(.footerNote); color = s(.color).isEmpty ? "blue" : s(.color); logoPath = s(.logoPath)
        invoicePattern = s(.invoicePattern).isEmpty ? "{YYYY}{NNNN}" : s(.invoicePattern)
        creditPattern = s(.creditPattern).isEmpty ? "D{YYYY}{NNN}" : s(.creditPattern)
        proformaPattern = s(.proformaPattern).isEmpty ? "Z{YYYY}{NNN}" : s(.proformaPattern)
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
    }
}

/// A customer.
public struct Client: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var name = ""
    public var street = "", city = "", zip = "", country = "SK"
    public var ico = "", dic = "", icDph = ""
    public var email = ""
    public var contactName = "", phone = ""
    public var note = ""
    public var source = "manual"
    public init() {}

    public var addressLines: [String] { [street, [zip, city].filter { !$0.isEmpty }.joined(separator: " "), country == "SK" ? "" : Country.name(country)].filter { !$0.isEmpty } }
    public var isForeign: Bool { country != "SK" }

    enum CodingKeys: String, CodingKey { case id, name, street, city, zip, country, ico, dic, icDph, email, contactName, phone, note, source }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        id = (try? c.decode(Int64.self, forKey: .id)) ?? 0
        name = s(.name); street = s(.street); city = s(.city); zip = s(.zip); country = s(.country).isEmpty ? "SK" : s(.country)
        ico = s(.ico); dic = s(.dic); icDph = s(.icDph); email = s(.email); contactName = s(.contactName); phone = s(.phone)
        note = s(.note); source = s(.source).isEmpty ? "manual" : s(.source)
    }
}

public enum InvoiceKind: String, Codable, CaseIterable, Hashable {
    case invoice, proforma, creditNote = "credit_note"
    public var title: String { switch self { case .invoice: "Faktúra"; case .proforma: "Zálohová faktúra"; case .creditNote: "Dobropis" } }
    public var pdfTitle: String { switch self { case .invoice: "Faktúra"; case .proforma: "Zálohová faktúra"; case .creditNote: "Dobropis – opravná faktúra" } }
    public var filePrefix: String { switch self { case .invoice: "Faktura"; case .proforma: "Zalohova-faktura"; case .creditNote: "Dobropis" } }
}

public enum InvoiceStatus: String, Codable, Hashable { case draft, issued, cancelled }

public enum VatMode: String, Codable, CaseIterable, Hashable {
    case standard, nonPayer = "non_payer", reverseCharge = "reverse_charge"
    public var label: String {
        switch self {
        case .standard: "S DPH"
        case .nonPayer: "Neplatiteľ DPH"
        case .reverseCharge: "Prenesenie daňovej povinnosti"
        }
    }
    public var chargesVat: Bool { self == .standard }
}

public enum PaymentMethod: String, Codable, CaseIterable, Hashable {
    case transfer, cash, card
    public var label: String { switch self { case .transfer: "Bankový prevod"; case .cash: "Hotovosť"; case .card: "Platobná karta" } }
}

public struct Item: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var description = ""
    public var quantity: Double = 1
    public var unit = "ks"
    public var unitPriceCents = 0
    public var vatRate: Double = 23
    public init(description: String = "", quantity: Double = 1, unit: String = "ks", unitPriceCents: Int = 0, vatRate: Double = 23) {
        self.description = description; self.quantity = quantity; self.unit = unit; self.unitPriceCents = unitPriceCents; self.vatRate = vatRate
    }
    /// Line total without VAT, rounded to cents.
    public var netCents: Int { Int((quantity * Double(unitPriceCents)).rounded(.toNearestOrAwayFromZero)) }
    /// UN/ECE Rec 20 code for the e-invoice later.
    public var unitCode: String { Units.code(unit) }

    enum CodingKeys: String, CodingKey { case id, description, quantity, unit, unitPriceCents, vatRate }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        quantity = (try? c.decode(Double.self, forKey: .quantity)) ?? 1
        unit = (try? c.decode(String.self, forKey: .unit)) ?? ""
        unitPriceCents = (try? c.decode(Int.self, forKey: .unitPriceCents)) ?? 0
        vatRate = (try? c.decode(Double.self, forKey: .vatRate)) ?? 0
    }
}

public enum Units {
    public static let common = ["ks", "hod", "deň", "mes", "km", "m²", "paušál"]
    public static func code(_ u: String) -> String {
        switch u.lowercased().trimmingCharacters(in: .whitespaces) {
        case "ks", "kus", "kusy", "": "C62"
        case "hod", "h", "hodina", "hodiny": "HUR"
        case "deň", "den", "dni", "dní", "md": "DAY"
        case "mes", "mesiac", "mesiace": "MON"
        case "km": "KMT"
        case "m²", "m2": "MTK"
        case "kg": "KGM"
        default: "C62"
        }
    }
}

public enum Country {
    public static func name(_ code: String) -> String {
        Locale(identifier: "sk_SK").localizedString(forRegionCode: code) ?? code
    }
}

public struct Payment: Codable, Hashable, Identifiable {
    public var id: Int64
    public var invoiceId: Int64
    public var date: String
    public var amountCents: Int
    public var method: String
    public var note: String
}

public struct VatGroup: Hashable {
    public var rate: Double
    public var baseCents: Int
    public var vatCents: Int
}

public struct Totals: Hashable {
    public var groups: [VatGroup]
    public var subtotalCents: Int
    public var vatCents: Int
    public var totalCents: Int

    /// VAT from the sum of bases per rate (rounded half away from zero), not per line.
    public static func compute(_ items: [Item], mode: VatMode) -> Totals {
        var bases: [Double: Int] = [:]
        for i in items { bases[mode.chargesVat ? i.vatRate : 0, default: 0] += i.netCents }
        let groups = bases.keys.sorted(by: >).map { r -> VatGroup in
            let base = bases[r]!
            let vat = mode.chargesVat ? Int((Double(base) * r / 100).rounded(.toNearestOrAwayFromZero)) : 0
            return VatGroup(rate: r, baseCents: base, vatCents: vat)
        }
        let sub = groups.reduce(0) { $0 + $1.baseCents }, vat = groups.reduce(0) { $0 + $1.vatCents }
        return Totals(groups: groups, subtotalCents: sub, vatCents: vat, totalCents: sub + vat)
    }
}

public struct Invoice: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var companyId: Int64 = 0
    public var kind: InvoiceKind = .invoice
    public var status: InvoiceStatus = .draft
    public var number: String?
    public var variableSymbol = ""
    public var clientId: Int64?
    public var client = Client()
    public var supplier: Company?
    public var issueDate = Day.today
    public var deliveryDate = Day.today
    public var dueDate = Day.today
    public var currency = "EUR"
    public var paymentMethod: PaymentMethod = .transfer
    public var vatMode: VatMode = .nonPayer
    public var vatNote = ""
    public var creditsInvoiceId: Int64?
    public var creditsNumber: String?
    public var creditsIssueDate: String?
    public var creditReason = ""
    public var proformaId: Int64?
    public var note = ""
    public var internalNote = ""
    public var items: [Item] = [Item()]
    public var subtotalCents = 0
    public var vatCents = 0
    public var totalCents = 0
    public var pdfPath: String?
    public var pdfSha: String?
    public var sentAt: String?
    public var sentVia: String?
    public var paidCents = 0
    public var paidAt: String?
    public var creditedCents = 0
    public var createdAt = ""
    public var updatedAt = ""
    public var issuedAt: String?
    /// Brought in from earlier invoicing with its original PDF (never rendered here).
    public var imported = false
    public init() {}

    public var totals: Totals { Totals.compute(items, mode: vatMode) }
    public var isDraft: Bool { status == .draft }
    /// What is still to be paid (credit notes count as paid down; a credit note itself is never "unpaid").
    public var balanceCents: Int { kind == .creditNote || status != .issued ? 0 : max(0, totalCents - paidCents - creditedCents) }
    public var isPaid: Bool { status == .issued && kind != .creditNote && balanceCents == 0 }
    public var isOverdue: Bool { balanceCents > 0 && dueDate < Day.today }
    public var displayNumber: String { number ?? "Koncept" }
    public var title: String { "\(kind.title) \(number ?? "(koncept)")" }
}

/// Days as yyyy-MM-dd strings (local time), so they sort and compare as text.
public enum Day {
    static let f: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    public static var today: String { f.string(from: Date()) }
    public static func string(_ d: Date) -> String { f.string(from: d) }
    public static func date(_ s: String) -> Date { f.date(from: s) ?? Date() }
    public static func adding(_ days: Int, to s: String) -> String { string(Calendar.current.date(byAdding: .day, value: days, to: date(s))!) }
    public static func diff(_ a: String, _ b: String) -> Int { Calendar.current.dateComponents([.day], from: date(a), to: date(b)).day ?? 0 }
    public static var now: String { ISO8601DateFormatter().string(from: Date()) }
    public static func sk(_ s: String) -> String {
        let p = s.split(separator: "-"); guard p.count == 3 else { return s }
        return "\(Int(p[2]) ?? 0). \(Int(p[1]) ?? 0). \(p[0])"
    }
}

public enum Money {
    static let fmt: NumberFormatter = {
        let f = NumberFormatter(); f.locale = Locale(identifier: "sk_SK"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.usesGroupingSeparator = true; return f
    }()
    public static func string(_ cents: Int, currency: String = "EUR") -> String {
        let s = fmt.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents)"
        return currency == "EUR" ? "\(s) €" : "\(s) \(currency)"
    }
    public static func plain(_ cents: Int) -> String { fmt.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents)" }
    public static func decimal(_ cents: Int) -> Decimal { Decimal(cents) / 100 }
    /// "1 234,50", "1234.5", "1 234 €" → cents.
    public static func parse(_ s: String) -> Int? {
        var t = s.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "\u{a0}", with: "").replacingOccurrences(of: " ", with: "")
        t = t.replacingOccurrences(of: "\u{202f}", with: "")
        if t.contains(",") { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        guard let d = Double(t) else { return nil }
        return Int((d * 100).rounded(.toNearestOrAwayFromZero))
    }
    public static func quantity(_ q: Double) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "sk_SK"); f.maximumFractionDigits = 3; f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: q)) ?? "\(q)"
    }
    public static func rate(_ r: Double) -> String { r == r.rounded() ? "\(Int(r)) %" : "\(Money.quantity(r)) %" }
}
