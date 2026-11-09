import FinancieCore
import Foundation

/// `Financie --demo <dir>`: a throwaway database with made-up data in <dir>, opened without the lock, for trying the app and
/// checking the design without touching real money. Faktúry isn't read in demo mode.
enum Demo {
    static func applyArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return }
        let dir = args[i + 1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FINANCIE_DB", dir + "/financie.sqlite", 1)
        setenv("FINANCIE_BACKUP_DIR", dir + "/backup", 1)
        setenv("FAKTURY_DB", dir + "/no-faktury.sqlite", 1)
        setenv("FINANCIE_DEMO", "1", 1)
    }

    static func fill(_ s: Store) {
        guard s.accounts().isEmpty else { return }
        do {
            let me = s.wallets().first!
            let firm = try s.saveWallet(Wallet(name: "10T Studios s. r. o.", kind: .business))
            let start = Day.adding(months: -11, to: Day.month(Day.today) + "-01")
            let tatra = try s.saveAccount(Account(walletId: me.id, name: "Tatra banka", type: .bank, openingCents: 420_000, openingDate: start))
            let savings = try s.saveAccount(Account(walletId: me.id, name: "Sporenie", type: .savings, openingCents: 1_200_000, openingDate: start))
            _ = try s.saveAccount(Account(walletId: me.id, name: "Hotovosť", type: .cash, openingCents: 15_000, openingDate: start))
            let firmBank = try s.saveAccount(Account(walletId: firm.id, name: "Bežný účet", type: .bank, openingCents: 1_850_000, openingDate: start))
            func cat(_ n: String) -> Int64? { s.category(named: n)?.id }
            var g = SystemRandomNumberGenerator()
            for k in 0..<12 {
                let m = Day.addMonths(Day.month(start), k)
                func d(_ day: Int) -> String { let p = m.split(separator: "-"); return Day.clamped(year: Int(p[0])!, month: Int(p[1])!, day: day) }
                guard d(1) <= Day.today else { break }
                let past = { (day: Int) in d(day) <= Day.today }
                if past(1) { try s.addTransaction(Tx(accountId: tatra.id, date: d(1), amountCents: 85_000, kind: .expense, categoryId: cat("Bývanie"), payee: "Nájom")) }
                if past(10) { try s.transfer(from: firmBank.id, to: tatra.id, cents: 260_000, date: d(10), note: "Výplata") }
                if past(5) { try s.addTransaction(Tx(accountId: firmBank.id, date: d(5), amountCents: Int.random(in: 380_000...720_000, using: &g), kind: .income, categoryId: cat("Faktúry"), payee: "Klient")) }
                if past(12) { try s.addTransaction(Tx(accountId: tatra.id, date: d(12), amountCents: Int.random(in: 9_000...16_000, using: &g), kind: .expense, categoryId: cat("Energie"), payee: "ZSE")) }
                if past(15) { try s.addTransaction(Tx(accountId: tatra.id, date: d(15), amountCents: 1_399, kind: .expense, categoryId: cat("Predplatné"), payee: "Netflix")) }
                if past(20) { try s.transfer(from: tatra.id, to: savings.id, cents: 50_000, date: d(20), note: "Sporenie") }
                if past(25) { try s.addTransaction(Tx(accountId: firmBank.id, date: d(25), amountCents: Int.random(in: 40_000...90_000, using: &g), kind: .expense, categoryId: cat("Softvér"), payee: "Cloud a nástroje")) }
                for day in stride(from: 2, through: 28, by: 4) where past(day) {
                    try s.addTransaction(Tx(accountId: tatra.id, date: d(day), amountCents: Int.random(in: 2_500...9_500, using: &g), kind: .expense, categoryId: cat("Potraviny"), payee: ["Lidl", "Billa", "Kaufland"].randomElement()!))
                }
                for day in [8, 18, 27] where past(day) {
                    try s.addTransaction(Tx(accountId: tatra.id, date: d(day), amountCents: Int.random(in: 1_800...6_500, using: &g), kind: .expense, categoryId: cat("Reštaurácie"), payee: ["Bistro", "Večera", "Obed"].randomElement()!))
                }
                if k % 3 == 1, past(16) { try s.addTransaction(Tx(accountId: tatra.id, date: d(16), amountCents: Int.random(in: 6_000...25_000, using: &g), kind: .expense, categoryId: cat("Oblečenie"), payee: "Zalando")) }
            }
            let today = Day.today
            func plan(_ r: Recurring, _ edit: (inout Recurring) -> Void = { _ in }) throws { var x = r; edit(&x); try s.saveRecurring(x) }
            try plan(Recurring(name: "Nájom", flow: .expense, accountId: tatra.id, amountCents: 85_000, frequency: .monthly, day: 1, startDate: today)) { $0.categoryId = cat("Bývanie") }
            try plan(Recurring(name: "Elektrina a plyn", flow: .expense, accountId: tatra.id, mode: .variable, amountCents: 12_000, frequency: .monthly, day: 12, startDate: today)) { $0.categoryId = cat("Energie") }
            try plan(Recurring(name: "Netflix", flow: .expense, accountId: tatra.id, amountCents: 1_399, frequency: .monthly, day: 15, startDate: today)) { $0.categoryId = cat("Predplatné") }
            try plan(Recurring(name: "Výplata z 10T", flow: .transfer, accountId: firmBank.id, mode: .composite, amountCents: 260_000, frequency: .monthly, day: 10, startDate: today)) {
                $0.toAccountId = tatra.id; $0.variableCents = 40_000
            }
            try plan(Recurring(name: "Faktúra Firma B", flow: .income, accountId: firmBank.id, mode: .variable, amountCents: 450_000, frequency: .monthly, day: 5, startDate: today)) { $0.categoryId = cat("Faktúry") }
            try plan(Recurring(name: "Poistenie auta", flow: .expense, accountId: tatra.id, amountCents: 42_000, frequency: .yearly, day: 3, startDate: Day.adding(months: 2, to: today))) { $0.categoryId = cat("Poistenie") }
            try plan(Recurring(name: "Daň z príjmov", flow: .expense, accountId: firmBank.id, mode: .irregular, amountCents: 380_000, frequency: .once, day: 31, startDate: Day.adding(months: 4, to: today))) { $0.categoryId = cat("Dane") }
            // one occurrence that is already late
            let late = try s.saveRecurring(Recurring(name: "Telefón", flow: .expense, accountId: tatra.id, mode: .variable, amountCents: 2_500, frequency: .monthly, day: 3, startDate: Day.adding(days: -3, to: today)))
            try s.db.run("UPDATE recurring SET created_at = ? WHERE id = ?", [Day.adding(days: -10, to: today), late.id])
        } catch { print("demo:", error) }
    }
}
