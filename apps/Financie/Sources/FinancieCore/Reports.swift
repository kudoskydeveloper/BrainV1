import Foundation

/// Balances, month summaries, the net worth history and the forecast. A scope is all money, one wallet or one account.
public struct Scope: Hashable {
    public var walletId: Int64?
    public var accountId: Int64?
    public init(walletId: Int64? = nil, accountId: Int64? = nil) { self.walletId = walletId; self.accountId = accountId }
    public static let all = Scope()
}

public struct MonthSummary {
    public let month: String
    /// Real income and expenses of the month (positive numbers). Transfers between my accounts don't count, except when the
    /// scope is one wallet and the money crosses into or out of it (salary from my company is income of the personal wallet).
    public var incomeCents = 0
    public var expenseCents = 0
    /// Per category, signed: income positive, expenses negative.
    public var byCategory: [(categoryId: Int64?, cents: Int)] = []
    /// Still expected this month from recurring items (late ones included), positive.
    public var expectedIncomeCents = 0
    public var expectedExpenseCents = 0
    public var netCents: Int { incomeCents - expenseCents }
}

public struct BalancePoint: Hashable, Identifiable {
    public let month: String
    public let cents: Int
    /// A forecast, not history.
    public let projected: Bool
    public var id: String { month + (projected ? "p" : "") }
    public init(month: String, cents: Int, projected: Bool) { self.month = month; self.cents = cents; self.projected = projected }
}

extension Store {
    func accountIds(_ s: Scope) -> [Int64] {
        if let a = s.accountId { return [a] }
        return accounts(includeArchived: true).filter { s.walletId == nil || $0.walletId == s.walletId }.map(\.id)
    }

    /// The balance at the end of `through` (opening balance plus transactions from the opening day on).
    public func balance(_ accountId: Int64, through: String = Day.today) -> Int {
        guard let a = account(accountId) else { return 0 }
        let sum = (try? db.run("SELECT COALESCE(SUM(amount_cents), 0) AS s FROM transactions WHERE account_id = ? AND date >= ? AND date <= ?",
                               [accountId, a.openingDate, through]).first?["s"]?.int) ?? 0
        return a.openingCents + (sum ?? 0)
    }

    public func balance(_ s: Scope, through: String = Day.today) -> Int {
        accountIds(s).reduce(0) { $0 + balance($1, through: through) }
    }

    /// Transactions dated after today (entered ahead), counted in the forecast.
    func futureCents(_ ids: [Int64], from: String, to: String) -> Int {
        guard !ids.isEmpty else { return 0 }
        let list = ids.map { String($0) }.joined(separator: ",")
        return (try? db.run("SELECT COALESCE(SUM(amount_cents), 0) AS s FROM transactions WHERE account_id IN (\(list)) AND date > ? AND date <= ?",
                            [from, to]).first?["s"]?.int ?? 0) ?? 0
    }

    /// What an expected occurrence does to the money in a scope (a transfer inside the scope does nothing).
    func effect(_ e: Expected, _ ids: Set<Int64>) -> Int {
        let r = e.recurring
        var c = 0
        if ids.contains(r.accountId) { c += e.amountCents }
        if r.flow == .transfer, let to = r.toAccountId, ids.contains(to) { c += r.expectedCents }
        return c
    }

    public func monthSummary(_ month: String = Day.month(Day.today), scope: Scope = .all) -> MonthSummary {
        var m = MonthSummary(month: month)
        let ids = Set(accountIds(scope))
        let rows = transactions(Store.Filter(accountIds: Array(ids), from: month + "-01", to: Day.monthEnd(month)))
        var cats: [Int64?: Int] = [:]
        for t in rows {
            switch t.kind {
            case .income: m.incomeCents += t.amountCents; cats[t.categoryId, default: 0] += t.amountCents
            case .expense: m.expenseCents -= t.amountCents; cats[t.categoryId, default: 0] += t.amountCents
            case .transfer:
                // counts only when the other side is outside the scope
                if scope != .all, let other = counterpart(t), !ids.contains(other.accountId) {
                    if t.amountCents > 0 { m.incomeCents += t.amountCents } else { m.expenseCents -= t.amountCents }
                }
            case .adjustment: break
            }
        }
        m.byCategory = cats.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        // the current month also carries what is late from earlier months
        let from: String? = month == Day.month(Day.today) ? nil : month + "-01"
        for e in expected(to: Day.monthEnd(month), from: from) {
            let c = effect(e, ids)
            if c > 0 { m.expectedIncomeCents += c } else { m.expectedExpenseCents -= c }
        }
        return m
    }

    /// Month-end balances for the last `months` months (the current month ends today).
    public func history(months: Int = 12, scope: Scope = .all) -> [BalancePoint] {
        let now = Day.month(Day.today)
        return (0..<months).reversed().map { k in
            let mo = Day.addMonths(now, -k)
            return BalancePoint(month: mo, cents: balance(scope, through: k == 0 ? Day.today : Day.monthEnd(mo)), projected: false)
        }
    }

    /// Month-end balances for the next `months` months: today's balance, plus transactions entered ahead, plus everything
    /// recurring items still expect (late ones in the current month).
    public func forecast(months: Int = 6, scope: Scope = .all) -> [BalancePoint] {
        let ids = accountIds(scope), set = Set(ids)
        let now = Day.month(Day.today)
        let start = balance(scope)
        let end = Day.monthEnd(Day.addMonths(now, months))
        let all = expected(to: end)
        return (0...months).map { k in
            let mo = Day.addMonths(now, k), last = Day.monthEnd(mo)
            let exp = all.filter { $0.dueDate <= last }.reduce(0) { $0 + effect($1, set) }
            return BalancePoint(month: mo, cents: start + futureCents(ids, from: Day.today, to: last) + exp, projected: k > 0)
        }
    }

    /// Recurring items per month, income and expenses separately (what the plan says a month looks like).
    public func plannedMonthly(scope: Scope = .all) -> (income: Int, expense: Int) {
        let ids = Set(accountIds(scope))
        var inc = 0, exp = 0
        for r in recurringItems(includeInactive: false) where r.frequency != .once {
            let e = effect(Expected(recurring: r, dueDate: Day.today), ids)
            let monthly = r.monthlyCents
            if e > 0 { inc += monthly } else if e < 0 { exp += monthly }
        }
        return (inc, exp)
    }
}
