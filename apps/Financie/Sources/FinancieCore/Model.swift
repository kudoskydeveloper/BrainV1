import Foundation

// MARK: Wallets and accounts

/// A wallet is whose money it is: me (personal) or one of my businesses (linked to its subject in Faktúry).
public enum WalletKind: String, Codable, CaseIterable, Hashable {
    case personal, business
    public var label: String { self == .personal ? "Osobné" : "Firma" }
}

public struct Wallet: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var name: String = ""
    public var kind: WalletKind = .personal
    /// The subject in Faktúry this wallet belongs to (its invoices are its income).
    public var fakturyCompanyId: Int64?
    public var archived = false
    public var sort = 0
    public init(id: Int64 = 0, name: String = "", kind: WalletKind = .personal, fakturyCompanyId: Int64? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.fakturyCompanyId = fakturyCompanyId
    }
}

public enum AccountType: String, Codable, CaseIterable, Hashable {
    case bank, savings, cash, card, investment
    public var label: String {
        switch self {
        case .bank: "Bežný účet"
        case .savings: "Sporenie"
        case .cash: "Hotovosť"
        case .card: "Kreditná karta"
        case .investment: "Investície"
        }
    }
    public var symbol: String {
        switch self {
        case .bank: "building.columns.fill"
        case .savings: "banknote.fill"
        case .cash: "dollarsign.circle.fill"
        case .card: "creditcard.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        }
    }
}

public struct Account: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var walletId: Int64 = 0
    public var name: String = ""
    public var type: AccountType = .bank
    public var currency = "EUR"
    public var iban = ""
    /// The balance on openingDate; transactions on or after it move it.
    public var openingCents = 0
    public var openingDate = Day.today
    public var archived = false
    public var sort = 0
    public init(id: Int64 = 0, walletId: Int64 = 0, name: String = "", type: AccountType = .bank, openingCents: Int = 0, openingDate: String = Day.today) {
        self.id = id; self.walletId = walletId; self.name = name; self.type = type; self.openingCents = openingCents; self.openingDate = openingDate
    }
}

// MARK: Categories and transactions

/// Income or expense (categories and recurring items); a transfer moves money between two of my accounts.
public enum Flow: String, Codable, CaseIterable, Hashable {
    case income, expense, transfer
    public var label: String {
        switch self {
        case .income: "Príjem"
        case .expense: "Výdavok"
        case .transfer: "Prevod"
        }
    }
    public var sign: Int { self == .expense ? -1 : 1 }
}

public struct TxCategory: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var name: String = ""
    public var flow: Flow = .expense
    public var symbol = "circle.fill"
    public var color = "gray"
    public var archived = false
    public init(id: Int64 = 0, name: String = "", flow: Flow = .expense, symbol: String = "circle.fill", color: String = "gray") {
        self.id = id; self.name = name; self.flow = flow; self.symbol = symbol; self.color = color
    }

    /// What a new database starts with (they can be renamed, added and archived).
    public static let defaults: [TxCategory] = [
        TxCategory(name: "Bývanie", flow: .expense, symbol: "house.fill", color: "orange"),
        TxCategory(name: "Energie a služby", flow: .expense, symbol: "bolt.fill", color: "yellow"),
        TxCategory(name: "Potraviny", flow: .expense, symbol: "cart.fill", color: "green"),
        TxCategory(name: "Reštaurácie", flow: .expense, symbol: "fork.knife", color: "red"),
        TxCategory(name: "Doprava", flow: .expense, symbol: "car.fill", color: "blue"),
        TxCategory(name: "Predplatné", flow: .expense, symbol: "repeat", color: "purple"),
        TxCategory(name: "Zdravie a šport", flow: .expense, symbol: "heart.fill", color: "pink"),
        TxCategory(name: "Oblečenie", flow: .expense, symbol: "tshirt.fill", color: "teal"),
        TxCategory(name: "Zábava", flow: .expense, symbol: "sparkles", color: "indigo"),
        TxCategory(name: "Cestovanie", flow: .expense, symbol: "airplane", color: "cyan"),
        TxCategory(name: "Poistenie", flow: .expense, symbol: "shield.fill", color: "brown"),
        TxCategory(name: "Dane a odvody", flow: .expense, symbol: "building.columns.fill", color: "gray"),
        TxCategory(name: "Softvér a služby", flow: .expense, symbol: "laptopcomputer", color: "mint"),
        TxCategory(name: "Darčeky", flow: .expense, symbol: "gift.fill", color: "pink"),
        TxCategory(name: "Ostatné výdavky", flow: .expense, symbol: "ellipsis.circle.fill", color: "gray"),
        TxCategory(name: "Plat", flow: .income, symbol: "banknote.fill", color: "green"),
        TxCategory(name: "Faktúry", flow: .income, symbol: "doc.text.fill", color: "orange"),
        TxCategory(name: "Dividendy", flow: .income, symbol: "chart.pie.fill", color: "purple"),
        TxCategory(name: "Investície", flow: .income, symbol: "chart.line.uptrend.xyaxis", color: "teal"),
        TxCategory(name: "Vrátené peniaze", flow: .income, symbol: "arrow.uturn.backward", color: "blue"),
        TxCategory(name: "Iné príjmy", flow: .income, symbol: "plus.circle.fill", color: "mint"),
    ]
}

/// What a transaction is: income, expense, one half of a transfer, or a correction after reconciling with the bank.
public enum TxKind: String, Codable, CaseIterable, Hashable {
    case income, expense, transfer, adjustment
    public var label: String {
        switch self {
        case .income: "Príjem"
        case .expense: "Výdavok"
        case .transfer: "Prevod"
        case .adjustment: "Korekcia zostatku"
        }
    }
}

public struct Tx: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var accountId: Int64 = 0
    public var date = Day.today
    /// Signed: money in is positive, money out negative.
    public var amountCents = 0
    public var kind: TxKind = .expense
    public var categoryId: Int64?
    /// Who was paid or who paid (shop, employer, client).
    public var payee = ""
    public var note = ""
    /// Both halves of a transfer share it.
    public var transferGroup: String?
    /// Set when the transaction confirms an expected occurrence of a recurring item.
    public var recurringId: Int64?
    public var dueDate: String?
    /// manual, mcp, faktury, import.
    public var source = "manual"
    public init(id: Int64 = 0, accountId: Int64 = 0, date: String = Day.today, amountCents: Int = 0, kind: TxKind = .expense, categoryId: Int64? = nil,
                payee: String = "", note: String = "") {
        self.id = id; self.accountId = accountId; self.date = date; self.amountCents = amountCents; self.kind = kind
        self.categoryId = categoryId; self.payee = payee; self.note = note
    }
}

// MARK: Recurring items

/// How the amount of a recurring item behaves.
public enum RecurringMode: String, Codable, CaseIterable, Hashable {
    /// The same amount every time (rent, subscription).
    case fixed
    /// Repeats, the amount changes; amountCents is the estimate, the real one is entered when it comes (electricity, phone).
    case variable
    /// A fixed part plus a variable one (salary with a bonus): amountCents fixed, variableCents the usual extra.
    case composite
    /// Expected once or now and then, with an estimate (a yearly bonus, a tax refund, a car service).
    case irregular
    public var label: String {
        switch self {
        case .fixed: "Fixná suma"
        case .variable: "Variabilná suma"
        case .composite: "Fixná + variabilná zložka"
        case .irregular: "Nepravidelná"
        }
    }
    public var help: String {
        switch self {
        case .fixed: "Vždy rovnaká suma, napríklad nájom alebo predplatné."
        case .variable: "Opakuje sa, ale suma sa mení. Zadáš odhad, skutočnú sumu potvrdíš, keď príde."
        case .composite: "Základ plus pohyblivá časť, napríklad plat s bonusom."
        case .irregular: "Príde raz alebo občas. Zadáš odhad sumy a kedy asi príde."
        }
    }
}

public enum Frequency: String, Codable, CaseIterable, Hashable {
    case weekly, monthly, quarterly, yearly, once
    public var label: String {
        switch self {
        case .weekly: "Každý týždeň"
        case .monthly: "Každý mesiac"
        case .quarterly: "Každý štvrťrok"
        case .yearly: "Každý rok"
        case .once: "Raz"
        }
    }
    /// How many times a year it comes (for the monthly equivalent).
    public var perYear: Double {
        switch self {
        case .weekly: 52
        case .monthly: 12
        case .quarterly: 4
        case .yearly: 1
        case .once: 0
        }
    }
}

public struct Recurring: Codable, Identifiable, Hashable {
    public var id: Int64 = 0
    public var name = ""
    public var flow: Flow = .expense
    public var accountId: Int64 = 0
    /// For a transfer: where the money goes (accountId is where it leaves from).
    public var toAccountId: Int64?
    public var categoryId: Int64?
    public var mode: RecurringMode = .fixed
    /// Positive. Fixed amount, the estimate (variable, irregular) or the fixed part (composite).
    public var amountCents = 0
    /// The usual variable part of a composite item.
    public var variableCents = 0
    public var frequency: Frequency = .monthly
    /// Every n-th period (every 2 months = monthly, interval 2).
    public var interval = 1
    /// Day of the month (monthly, quarterly, yearly); 31 means the last day.
    public var day = 1
    public var startDate = Day.today
    public var endDate: String?
    public var payee = ""
    public var note = ""
    public var active = true
    public var createdAt = Day.today
    public init(id: Int64 = 0, name: String = "", flow: Flow = .expense, accountId: Int64 = 0, mode: RecurringMode = .fixed, amountCents: Int = 0,
                frequency: Frequency = .monthly, day: Int = 1, startDate: String = Day.today) {
        self.id = id; self.name = name; self.flow = flow; self.accountId = accountId; self.mode = mode; self.amountCents = amountCents
        self.frequency = frequency; self.day = day; self.startDate = startDate
    }

    /// What one occurrence is expected to be (positive).
    public var expectedCents: Int { mode == .composite ? amountCents + variableCents : amountCents }
    /// About how much it is per month (0 for a one-off).
    public var monthlyCents: Int { Int((Double(expectedCents) * frequency.perYear / 12 / Double(max(interval, 1))).rounded()) }
}

/// One expected occurrence of a recurring item that hasn't been confirmed or skipped yet.
public struct Expected: Hashable, Identifiable {
    public let recurring: Recurring
    public let dueDate: String
    public var id: String { "\(recurring.id)@\(dueDate)" }
    /// Signed for the account it leaves from (a transfer is negative here and positive on toAccountId).
    public var amountCents: Int { recurring.flow == .income ? recurring.expectedCents : -recurring.expectedCents }
    public var isLate: Bool { dueDate < Day.today }
}

// MARK: Days and money

public enum Day {
    static let f: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let cal = Calendar(identifier: .gregorian)
    public static var today: String { f.string(from: Date()) }
    public static func string(_ d: Date) -> String { f.string(from: d) }
    public static func date(_ s: String) -> Date { f.date(from: s) ?? Date() }
    public static func valid(_ s: String) -> Bool { s.count == 10 && f.date(from: s) != nil }
    public static func adding(days: Int, to s: String) -> String { string(cal.date(byAdding: .day, value: days, to: date(s))!) }
    public static func adding(months: Int, to s: String) -> String { string(cal.date(byAdding: .month, value: months, to: date(s))!) }
    public static func diff(_ a: String, _ b: String) -> Int { cal.dateComponents([.day], from: date(a), to: date(b)).day ?? 0 }
    public static var now: String { ISO8601DateFormatter().string(from: Date()) }
    /// "2026-11" → "2026-11-30".
    public static func monthEnd(_ month: String) -> String {
        let first = date(month + "-01")
        return string(cal.date(byAdding: DateComponents(month: 1, day: -1), to: first)!)
    }
    public static func month(_ s: String) -> String { String(s.prefix(7)) }
    public static func addMonths(_ month: String, _ n: Int) -> String { String(adding(months: n, to: month + "-01").prefix(7)) }
    /// The day in that month, clamped to its length (31 → 30. novembra).
    public static func clamped(year: Int, month: Int, day: Int) -> String {
        let first = cal.date(from: DateComponents(year: year, month: month, day: 1))!
        let n = cal.range(of: .day, in: .month, for: first)!.count
        return string(cal.date(from: DateComponents(year: year, month: month, day: min(max(day, 1), n)))!)
    }
    public static func sk(_ s: String) -> String {
        let p = s.split(separator: "-"); guard p.count == 3 else { return s }
        return "\(Int(p[2]) ?? 0). \(Int(p[1]) ?? 0). \(p[0])"
    }
    static let months = ["január", "február", "marec", "apríl", "máj", "jún", "júl", "august", "september", "október", "november", "december"]
    /// "2026-11" → "november 2026".
    public static func monthName(_ month: String, year: Bool = true) -> String {
        let p = month.split(separator: "-"); guard p.count >= 2, let m = Int(p[1]), (1...12).contains(m) else { return month }
        return year ? "\(months[m - 1]) \(p[0])" : months[m - 1]
    }
}

public enum Money {
    static let fmt: NumberFormatter = {
        let f = NumberFormatter(); f.locale = Locale(identifier: "sk_SK"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.usesGroupingSeparator = true; return f
    }()
    static let whole: NumberFormatter = {
        let f = NumberFormatter(); f.locale = Locale(identifier: "sk_SK"); f.numberStyle = .decimal
        f.maximumFractionDigits = 0; f.usesGroupingSeparator = true; return f
    }()
    public static func string(_ cents: Int, currency: String = "EUR", signed: Bool = false) -> String {
        let s = fmt.string(from: NSNumber(value: Double(abs(cents)) / 100)) ?? "\(cents)"
        let sign = cents < 0 ? "−" : (signed && cents > 0 ? "+" : "")
        return currency == "EUR" ? "\(sign)\(s) €" : "\(sign)\(s) \(currency)"
    }
    /// Without cents, for charts and big numbers.
    public static func short(_ cents: Int) -> String {
        let s = whole.string(from: NSNumber(value: (Double(abs(cents)) / 100).rounded())) ?? "\(cents / 100)"
        return (cents < 0 ? "−" : "") + s + " €"
    }
    public static func euros(_ cents: Int) -> Double { Double(cents) / 100 }
    /// "1 234,50", "1234.5", "1 234 €", "-45" → cents.
    public static func parse(_ s: String) -> Int? {
        var t = s.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "EUR", with: "")
        for ws in [" ", "\u{a0}", "\u{202f}"] { t = t.replacingOccurrences(of: ws, with: "") }
        t = t.replacingOccurrences(of: "−", with: "-")
        if t.contains(",") { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        guard !t.isEmpty, let d = Double(t) else { return nil }
        return Int((d * 100).rounded(.toNearestOrAwayFromZero))
    }
}
