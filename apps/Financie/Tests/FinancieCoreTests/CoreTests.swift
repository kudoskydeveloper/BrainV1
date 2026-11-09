import XCTest
@testable import FinancieCore

final class CoreTests: XCTestCase {
    var store: Store!
    var personal: Wallet!
    var bank: Account!

    override func setUp() {
        let path = NSTemporaryDirectory() + "financie-test-\(UUID().uuidString).sqlite"
        store = try! Store(path: path)
        personal = store.wallets().first!
        bank = try! store.saveAccount(Account(walletId: personal.id, name: "Tatra", type: .bank, openingCents: 100_000, openingDate: "2026-01-01"))
    }

    func testSeed() {
        XCTAssertEqual(store.wallets().map(\.name), ["Osobné"])
        XCTAssertTrue(store.categories().contains { $0.name == "Plat" && $0.flow == .income })
        XCTAssertEqual(store.category(named: "restauracie")?.name, "Reštaurácie")
    }

    func testSignsAndBalance() throws {
        let food = store.category(named: "Potraviny")!
        try store.addTransaction(Tx(accountId: bank.id, date: "2026-02-01", amountCents: 4_550, kind: .expense, categoryId: food.id, payee: "Lidl"))
        try store.addTransaction(Tx(accountId: bank.id, date: "2026-02-03", amountCents: -200_000, kind: .income, categoryId: store.category(named: "Plat")!.id))
        XCTAssertEqual(store.balance(bank.id), 100_000 - 4_550 + 200_000)
        XCTAssertEqual(store.balance(bank.id, through: "2026-02-02"), 100_000 - 4_550)
        let feb = store.monthSummary("2026-02")
        XCTAssertEqual(feb.expenseCents, 4_550)
        XCTAssertEqual(feb.byCategory.first { $0.categoryId == food.id }?.cents, -4_550)
        // a transaction before the opening day is already in the opening balance
        try store.addTransaction(Tx(accountId: bank.id, date: "2025-12-31", amountCents: 999, kind: .expense))
        XCTAssertEqual(store.balance(bank.id), 100_000 - 4_550 + 200_000)
        XCTAssertThrowsError(try store.addTransaction(Tx(accountId: bank.id, amountCents: 100, kind: .income, categoryId: food.id)))
    }

    func testTransferAcrossWallets() throws {
        let firm = try store.saveWallet(Wallet(name: "10T", kind: .business))
        let firmBank = try store.saveAccount(Account(walletId: firm.id, name: "Firma", openingCents: 500_000, openingDate: "2026-01-01"))
        let today = Day.today
        let pair = try store.transfer(from: firmBank.id, to: bank.id, cents: 150_000, date: today, note: "Výplata")
        XCTAssertEqual(pair.map(\.amountCents), [-150_000, 150_000])
        XCTAssertEqual(store.balance(.all), 600_000)
        let personalMonth = store.monthSummary(Day.month(today), scope: Scope(walletId: personal.id))
        XCTAssertEqual(personalMonth.incomeCents, 150_000)
        XCTAssertEqual(store.monthSummary(Day.month(today)).incomeCents, 0)
        var t = pair[0]; t.amountCents = -120_000
        try store.updateTransaction(t)
        XCTAssertEqual(store.balance(bank.id), 220_000)
        try store.deleteTransaction(pair[1].id)
        XCTAssertEqual(store.balance(.all), 600_000)
        XCTAssertTrue(store.transactions().isEmpty)
    }

    func testReconcile() throws {
        let t = try store.reconcile(accountId: bank.id, balanceCents: 123_456)
        XCTAssertEqual(t?.amountCents, 23_456)
        XCTAssertEqual(store.balance(bank.id), 123_456)
        XCTAssertNil(try store.reconcile(accountId: bank.id, balanceCents: 123_456))
    }

    func testScheduleDates() {
        var r = Recurring(name: "Nájom", accountId: 1, amountCents: 80_000, frequency: .monthly, day: 31, startDate: "2026-01-15")
        XCTAssertEqual(Schedule.dates(r, from: "2026-01-01", to: "2026-04-30"), ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
        r.frequency = .quarterly; r.day = 10
        XCTAssertEqual(Schedule.dates(r, from: "2026-01-01", to: "2026-12-31"), ["2026-04-10", "2026-07-10", "2026-10-10"])
        r.frequency = .weekly; r.startDate = "2026-03-02"
        XCTAssertEqual(Schedule.dates(r, from: "2026-03-10", to: "2026-03-24"), ["2026-03-16", "2026-03-23"])
        r.frequency = .monthly; r.interval = 2; r.day = 5; r.startDate = "2020-01-05"
        XCTAssertEqual(Schedule.dates(r, from: "2026-01-01", to: "2026-06-30"), ["2026-01-05", "2026-03-05", "2026-05-05"])
        r.frequency = .once; r.startDate = "2026-05-05"; r.endDate = nil
        XCTAssertEqual(Schedule.dates(r, from: "2026-01-01", to: "2026-12-31"), ["2026-05-05"])
    }

    func testExpectedConfirmSkipAndForecast() throws {
        let today = Day.today
        let salary = try store.saveRecurring({
            var r = Recurring(name: "Plat", flow: .income, accountId: bank.id, mode: .composite, amountCents: 200_000, frequency: .monthly, day: 10, startDate: today)
            r.variableCents = 50_000; r.categoryId = store.category(named: "Plat")!.id; return r
        }())
        let rent = try store.saveRecurring(Recurring(name: "Nájom", flow: .expense, accountId: bank.id, mode: .fixed, amountCents: 80_000, frequency: .monthly, day: 1, startDate: today))
        let horizon = Day.monthEnd(Day.addMonths(Day.month(today), 2))
        let exp = store.expected(to: horizon)
        XCTAssertEqual(exp.filter { $0.recurring.id == salary.id }.first?.amountCents, 250_000)
        XCTAssertEqual(exp.filter { $0.recurring.id == rent.id }.first?.amountCents, -80_000)
        // forecast in 2 months: every salary and rent until then
        let n = { (id: Int64) in exp.filter { $0.recurring.id == id }.count }
        let f = store.forecast(months: 2)
        XCTAssertEqual(f.last!.cents, 100_000 + n(salary.id) * 250_000 - n(rent.id) * 80_000)
        // confirm the first salary with the real amount, skip the first rent
        let first = exp.first { $0.recurring.id == salary.id }!
        let made = try store.confirm(recurringId: salary.id, dueDate: first.dueDate, amountCents: 231_000)
        XCTAssertEqual(made.first?.amountCents, 231_000)
        XCTAssertEqual(made.first?.kind, .income)
        let firstRent = exp.first { $0.recurring.id == rent.id }!
        try store.skip(recurringId: rent.id, dueDate: firstRent.dueDate)
        XCTAssertFalse(store.expected(to: horizon).contains { $0.id == first.id || $0.id == firstRent.id })
        XCTAssertThrowsError(try store.confirm(recurringId: salary.id, dueDate: first.dueDate))
        // deleting the transaction makes the occurrence expected again
        try store.deleteTransaction(made[0].id)
        XCTAssertTrue(store.expected(to: horizon).contains { $0.id == first.id })
        XCTAssertEqual(salary.monthlyCents, 250_000)
    }

    func testRecurringTransferForecastPerWallet() throws {
        let firm = try store.saveWallet(Wallet(name: "10T", kind: .business))
        let firmBank = try store.saveAccount(Account(walletId: firm.id, name: "Firma", openingCents: 0, openingDate: "2026-01-01"))
        var r = Recurring(name: "Výplata z firmy", flow: .transfer, accountId: firmBank.id, mode: .fixed, amountCents: 100_000, frequency: .monthly, day: 28, startDate: Day.today)
        r.toAccountId = bank.id
        r = try store.saveRecurring(r)
        let f = store.forecast(months: 1, scope: Scope(walletId: personal.id))
        let all = store.forecast(months: 1)
        XCTAssertGreaterThan(f.last!.cents, 100_000)
        XCTAssertEqual(all.last!.cents, 100_000)   // inside all money a transfer changes nothing
        let e = store.expected(to: Day.monthEnd(Day.addMonths(Day.month(Day.today), 1))).first!
        let pair = try store.confirm(recurringId: r.id, dueDate: e.dueDate)
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(store.balance(bank.id, through: "2099-01-01"), 200_000)
    }

    func testLateOccurrencesFromStartAtMost90Days() throws {
        let start = Day.adding(days: -20, to: Day.today)
        let r = try store.saveRecurring(Recurring(name: "Od priateľky", flow: .income, accountId: bank.id, amountCents: 30_000, frequency: .weekly, startDate: start))
        let late = store.expected(to: Day.today).filter { $0.recurring.id == r.id && $0.isLate }
        XCTAssertEqual(late.first?.dueDate, start)
        let old = try store.saveRecurring(Recurring(name: "Netflix", flow: .expense, accountId: bank.id, amountCents: 1_399, frequency: .monthly, day: 1, startDate: "2020-01-01"))
        let oldLate = store.expected(to: Day.today).filter { $0.recurring.id == old.id && $0.isLate }
        XCTAssertTrue(oldLate.allSatisfy { Day.diff($0.dueDate, Day.today) <= 90 })
        XCTAssertFalse(oldLate.isEmpty)
        // confirmed on a day before the account's opening balance: counts in the month, not twice in the balance
        let acc = try store.saveAccount(Account(walletId: personal.id, name: "Nový", openingCents: 330_000, openingDate: Day.today))
        var x = try store.saveRecurring(Recurring(name: "Príspevok", flow: .income, accountId: acc.id, amountCents: 30_000, frequency: .monthly, day: 1, startDate: start))
        x = store.recurringItem(x.id)!
        let e = store.expected(to: Day.today).first { $0.recurring.id == x.id }!
        try store.confirm(recurringId: x.id, dueDate: e.dueDate)
        XCTAssertEqual(store.balance(acc.id), 330_000)
    }

    func testFakturySync() throws {
        let path = NSTemporaryDirectory() + "faktury-\(UUID().uuidString).sqlite"
        let f = try DB(path: path)
        try f.exec("CREATE TABLE companies(id INTEGER PRIMARY KEY, name TEXT, data TEXT, archived INTEGER DEFAULT 0)")
        try f.run("INSERT INTO companies(id, name, data) VALUES (1, '10T Studios s. r. o.', '{\"iban\":\"SK37 1100\"}')")
        let made = try FakturyLink.sync(store, path: path)
        XCTAssertEqual(made.map(\.name), ["10T Studios s. r. o."])
        XCTAssertEqual(store.accounts().first { $0.walletId == made[0].id }?.iban, "SK371100")
        XCTAssertTrue(try FakturyLink.sync(store, path: path).isEmpty)
    }

    func testMoneyParse() {
        XCTAssertEqual(Money.parse("1 234,50 €"), 123_450)
        XCTAssertEqual(Money.parse("45"), 4_500)
        XCTAssertEqual(Money.parse("−12.3"), -1_230)
        XCTAssertEqual(Money.string(-123_450).replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " "), "−1 234,50 €")
    }
}
