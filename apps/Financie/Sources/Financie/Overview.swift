import Charts
import FinancieCore
import SwiftUI

/// All money or one wallet: balances, the balance over time with the forecast, this month, categories and what's coming.
struct OverviewPage: View {
    @ObservedObject var model: AppModel
    let scope: Scope
    var title = "Prehľad"

    var body: some View {
        let _ = model.version
        let store = model.store
        let month = store.monthSummary(scope: scope)
        let ids = Set(store.accounts(includeArchived: true).filter { scope.walletId == nil || $0.walletId == scope.walletId }.map(\.id))
        let soon = model.expected.filter { $0.dueDate <= Day.adding(days: 14, to: Day.today) && touches($0, ids) }
        let history = store.history(months: 12, scope: scope), forecast = store.forecast(months: 6, scope: scope)
        ScrollPage {
            tiles(month: month, forecast: forecast)
            Card("Zostatok a prognóza", subtitle: "Posledný rok a plán na šesť mesiacov") { BalanceChart(history: history, forecast: forecast) }
            Card(monthTitle(month.month), subtitle: "Príjmy, výdavky a kam išli peniaze") {
                MonthBreakdown(month: month, plan: store.plannedMonthly(scope: scope), model: model)
            }
            Card("Príjmy a výdavky", subtitle: "Posledných šesť mesiacov") {
                FlowChart(points: (0..<6).reversed().map { k in store.monthSummary(Day.addMonths(Day.month(Day.today), -k), scope: scope) })
            }
            Card("Najbližšie dva týždne", subtitle: soon.isEmpty ? nil : "Potvrď, keď to príde, so skutočnou sumou") { UpcomingList(items: soon, model: model) }
        }
        .navigationTitle(title)
        .navigationSubtitle(scope.walletId == nil ? "Všetky peňaženky" : (model.wallet(scope.walletId)?.kind.label ?? ""))
    }

    func touches(_ e: Expected, _ ids: Set<Int64>) -> Bool {
        ids.contains(e.recurring.accountId) || (e.recurring.toAccountId.map(ids.contains) ?? false)
    }

    @ViewBuilder func tiles(month: MonthSummary, forecast: [BalancePoint]) -> some View {
        let net = month.netCents
        StatGrid {
            if let w = scope.walletId {
                let accs = model.accounts.filter { $0.walletId == w }
                StatTile("Spolu", Money.string(accs.reduce(0) { $0 + (model.balances[$1.id] ?? 0) }), detail: "\(accs.count) účtov", symbol: "eurosign.circle.fill", tint: .pink)
                ForEach(accs.prefix(2)) { a in
                    StatTile(a.name, Money.string(model.balances[a.id] ?? 0), detail: a.type.label, symbol: a.type.symbol, tint: a.type.color)
                }
            } else {
                StatTile("Čistý majetok", Money.string(model.total()), detail: "\(model.accounts.count) účtov", symbol: "eurosign.circle.fill", tint: .pink)
                StatTile("Osobné", Money.string(model.total(.personal)), detail: "moje účty", symbol: "person.fill", tint: .blue)
                StatTile("Firmy", Money.string(model.total(.business)), detail: model.wallets.filter { $0.kind == .business }.map(\.name).joined(separator: ", "),
                         symbol: "building.2.fill", tint: .orange)
            }
            StatTile("Tento mesiac", Money.string(net, signed: true), detail: "príjmy \(Money.short(month.incomeCents)) · výdavky \(Money.short(month.expenseCents))",
                     symbol: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill", tint: net >= 0 ? .green : .red)
            if let last = forecast.last {
                StatTile("O šesť mesiacov", Money.string(last.cents), detail: "podľa plánu, \(Day.monthName(last.month))", symbol: "calendar.badge.clock", tint: .purple)
            }
        }
    }
}

/// Balance at the end of each month: the last year solid, the next six months dashed.
struct BalanceChart: View {
    let history: [BalancePoint]
    let forecast: [BalancePoint]

    var body: some View {
        let points = history + forecast.dropFirst()
        let bridge = history.last.map { BalancePoint(month: $0.month, cents: $0.cents, projected: true) }
        Chart {
            ForEach(history) { p in
                AreaMark(x: .value("Mesiac", p.month), y: .value("Zostatok", Money.euros(p.cents)))
                    .foregroundStyle(.linearGradient(colors: [.pink.opacity(0.28), .pink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Mesiac", p.month), y: .value("Zostatok", Money.euros(p.cents)), series: .value("Druh", "História"))
                    .foregroundStyle(.pink).lineStyle(StrokeStyle(lineWidth: 2.5)).interpolationMethod(.monotone)
            }
            ForEach([bridge].compactMap { $0 } + forecast.dropFirst()) { p in
                LineMark(x: .value("Mesiac", p.month), y: .value("Zostatok", Money.euros(p.cents)), series: .value("Druh", "Prognóza"))
                    .foregroundStyle(.purple.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4])).interpolationMethod(.monotone)
            }
            if let now = history.last {
                PointMark(x: .value("Mesiac", now.month), y: .value("Zostatok", Money.euros(now.cents))).foregroundStyle(.pink).symbolSize(60)
                    .annotation(position: .top, alignment: .center, spacing: 6) {
                        Text(Money.short(now.cents)).font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.background, in: .capsule)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.month)) { v in
                if let m = v.as(String.self) { AxisValueLabel { Text(Day.monthName(m, year: false).prefix(3)) } }
            }
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(Int(d * 100))) } } } }
        .frame(height: 220)
    }
}

/// The month: income and expenses with what's still expected on the left, where the money went on the right.
struct MonthBreakdown: View {
    let month: MonthSummary
    let plan: (income: Int, expense: Int)
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                line("Príjmy", month.incomeCents, expected: month.expectedIncomeCents, symbol: "arrow.down.circle.fill", tint: .green)
                line("Výdavky", month.expenseCents, expected: month.expectedExpenseCents, symbol: "arrow.up.circle.fill", tint: .pink)
                Divider()
                HStack {
                    Text("Bilancia").font(.headline)
                    Spacer()
                    Text(Money.string(month.netCents, signed: true)).font(.headline.monospacedDigit()).foregroundStyle(month.netCents >= 0 ? .green : .red)
                }
                if plan.income > 0 || plan.expense > 0 {
                    Text("Plán na mesiac: príjmy \(Money.short(plan.income)), výdavky \(Money.short(plan.expense))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 280)
            Divider()
            categories.frame(maxWidth: .infinity)
        }
    }

    func line(_ title: String, _ cents: Int, expected: Int, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).foregroundStyle(tint).font(.subheadline.weight(.medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Money.string(cents)).font(.title3.weight(.semibold).monospacedDigit())
                if expected > 0 { Text("ešte čaká \(Money.string(expected))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder var categories: some View {
        let rows = Array(month.byCategory.filter { $0.cents < 0 }.sorted { $0.cents < $1.cents }.prefix(6))
        if rows.isEmpty {
            Text("Tento mesiac zatiaľ žiadne výdavky.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
        } else {
            let maxV = Double(-(rows.first?.cents ?? 1))
            VStack(spacing: 8) {
                ForEach(rows, id: \.categoryId) { r in
                    let c = model.category(r.categoryId)
                    let color = Color.named(c?.color ?? "gray")
                    HStack(spacing: 10) {
                        IconBadge(symbol: c?.symbol ?? "questionmark", color: color, size: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c?.name ?? "Bez kategórie").lineLimit(1)
                                Spacer()
                                Text(Money.string(-r.cents)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.fill.tertiary)
                                    Capsule().fill(color.gradient).frame(width: max(6, g.size.width * Double(-r.cents) / maxV))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }
}

/// Income and expenses of the last six months side by side.
struct FlowChart: View {
    let points: [MonthSummary]
    var body: some View {
        Chart {
            ForEach(points, id: \.month) { m in
                BarMark(x: .value("Mesiac", m.month), y: .value("Suma", Money.euros(m.incomeCents)))
                    .foregroundStyle(by: .value("Druh", "Príjmy")).position(by: .value("Druh", "Príjmy")).cornerRadius(5)
                BarMark(x: .value("Mesiac", m.month), y: .value("Suma", Money.euros(m.expenseCents)))
                    .foregroundStyle(by: .value("Druh", "Výdavky")).position(by: .value("Druh", "Výdavky")).cornerRadius(5)
            }
        }
        .chartForegroundStyleScale(["Príjmy": Color.green.gradient, "Výdavky": Color.pink.gradient])
        .chartLegend(position: .top, alignment: .trailing)
        .chartXAxis { AxisMarks { v in AxisValueLabel { if let m = v.as(String.self) { Text(Day.monthName(m, year: false).prefix(3)) } } } }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(Int(d * 100))) } } } }
        .frame(height: 180)
    }
}

/// Late and coming in the next two weeks, with a confirm button.
struct UpcomingList: View {
    let items: [Expected]
    @ObservedObject var model: AppModel
    var body: some View {
        if items.isEmpty {
            Text("Nič naplánované. Pravidelné príjmy a výdavky pridáš v Pravidelné.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { e in
                    ExpectedRow(e: e, model: model)
                    if e.id != items.last?.id { Divider().padding(.leading, 40) }
                }
            }
        }
    }
}
