import Charts
import FakturyCore
import SwiftUI

struct OverviewList: View {
    @ObservedObject var model: AppModel
    let year = Int(Day.today.prefix(4))!

    var body: some View {
        List(selection: $model.selection) {
            Section("Rok \(String(year))") {
                ForEach(model.companies) { c in
                    let net = model.store.monthly(companyId: c.id, year: year).reduce(0) { $0 + $1.netCents }
                    HStack(spacing: 10) {
                        CompanyMark(company: c, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.shortName).font(.body.weight(.medium))
                            Text(c.legalForm == .company ? "Firma" : "Živnosť").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.string(net)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(Pick.company(c.id))
                }
            }
        }
        .navigationTitle("Prehľad príjmov")
    }
}

/// Income per month (without VAT), what's open and overdue. For one subject or all of them.
struct OverviewDetail: View {
    @ObservedObject var model: AppModel
    let company: Company?
    @State private var year = Int(Day.today.prefix(4))!

    var months: [Store.MonthTotal] { model.store.monthly(companyId: company?.id, year: year) }
    var docs: [Invoice] { company.map { c in model.invoices.filter { $0.companyId == c.id } } ?? model.invoices }

    var body: some View {
        Page {
            HStack {
                Text(company?.name ?? "Všetky subjekty").font(.title2.weight(.semibold))
                Spacer()
                Picker("Rok", selection: $year) { ForEach((year - 4)...(Int(Day.today.prefix(4))!), id: \.self) { Text(String($0)).tag($0) } }
                    .labelsHidden().frame(width: 90)
            }
            let thisMonth = months.first { $0.month == String(Day.today.prefix(7)) }?.netCents ?? 0
            let open = docs.filter { $0.balanceCents > 0 }
            StatGrid {
                StatTile("Tento mesiac", Money.string(thisMonth), detail: "bez DPH", symbol: "calendar", tint: .blue)
                StatTile("Rok \(String(year))", Money.string(months.reduce(0) { $0 + $1.netCents }), detail: "\(months.reduce(0) { $0 + $1.count }) dokladov · bez DPH",
                         symbol: "chart.bar.fill", tint: .green)
                StatTile("Neuhradené", Money.string(open.reduce(0) { $0 + $1.balanceCents }), detail: "\(open.count) faktúr", symbol: "clock", tint: .orange)
                StatTile("Po splatnosti", Money.string(open.filter(\.isOverdue).reduce(0) { $0 + $1.balanceCents }),
                         detail: "\(open.filter(\.isOverdue).count) faktúr", symbol: "exclamationmark.circle", tint: .red)
            }
            Card("Príjmy podľa mesiacov", symbol: "chart.bar.xaxis", tint: .green) {
                if months.isEmpty {
                    Text("V roku \(String(year)) zatiaľ nie sú vystavené faktúry.").foregroundStyle(.secondary)
                } else {
                    Chart(allMonths, id: \.0) { m, cents in
                        BarMark(x: .value("Mesiac", Fmt.shortMonth(m)), y: .value("Suma", Double(cents) / 100))
                            .foregroundStyle(Palette.color(company?.color ?? "green").gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) €") } } } }
                    .frame(height: 220)
                }
            }
            let overdue = open.filter(\.isOverdue)
            if !overdue.isEmpty {
                Card("Po splatnosti", symbol: "exclamationmark.circle.fill", tint: .red) {
                    ForEach(overdue) { i in
                        Button { model.folder = .overdue; model.selection = .invoice(i.id) } label: {
                            InvoiceRow(i: i, company: model.company(i.companyId), showCompany: company == nil && model.companies.count > 1).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Label(model.lastBackup.map { "Posledná záloha \(Fmt.day(String($0.prefix(10)))) do iCloud Drive › Faktúry" } ?? "Zatiaľ bez zálohy", systemImage: "externaldrive.badge.icloud")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Zálohovať teraz") { model.backupNow() }.controlSize(.small)
                Button("Import starých faktúr…") { model.showImport = true }.controlSize(.small)
                Button("Export pre účtovníčku…") { model.showExport = true }.controlSize(.small)
            }
        }
        .navigationTitle("Prehľad príjmov")
    }

    var allMonths: [(String, Int)] {
        let byMonth = Dictionary(uniqueKeysWithValues: months.map { ($0.month, $0.netCents) })
        let last = year == Int(Day.today.prefix(4))! ? Int(Day.today.dropFirst(5).prefix(2))! : 12
        return (1...last).map { m in let k = String(format: "%d-%02d", year, m); return (k, byMonth[k] ?? 0) }
    }
}

struct ExportSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var companyId: Int64 = 0
    @State private var month = String(Day.adding(-20, to: Day.today).prefix(7))

    var months: [String] {
        (0..<18).map { n in String(Day.string(Calendar.current.date(byAdding: .month, value: -n, to: Date())!).prefix(7)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export pre účtovníčku").font(.title3.weight(.semibold))
            Text("Priečinok v Stiahnutých s PDF všetkých dokladov za mesiac a CSV prehľadom (základ a DPH podľa sadzieb, úhrady).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Subjekt", selection: $companyId) { ForEach(model.companies) { Text($0.name).tag($0.id) } }
            Picker("Mesiac", selection: $month) { ForEach(months, id: \.self) { Text(Fmt.month($0)).tag($0) } }
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Exportovať") {
                    model.run {
                        let dir = try AccountantExport.export(model.store, companyId: companyId, month: month,
                                                              to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { companyId = model.companies.first?.id ?? 0 }
    }
}

/// How old invoices get in: PDFs into the Import folder, then Brain (or Claude) reads them and imports after you confirm.
struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: [PendingImport] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import starých faktúr").font(.title3.weight(.semibold))
            Text("Vlož PDF už vystavených faktúr do priečinka Import (iCloud Drive › Faktúry › Import). Potom povedz Brainu „importuj faktúry“: prečíta ich, ukáže ti tabuľku na kontrolu a po tvojom áno ich uloží ako archívne záznamy s pôvodným PDF. Započítajú sa do prehľadu, neuhradených aj odberateľov a číselný rad na ne nadviaže.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card("Čaká na import", symbol: "tray.and.arrow.down", tint: .teal) {
                if pending.isEmpty { Text("Priečinok je prázdny.").foregroundStyle(.secondary) }
                ForEach(pending, id: \.url) { p in
                    HStack {
                        Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                        Text(p.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        if p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Pill(text: "bez textu", color: .orange) }
                    }
                }
            }
            HStack {
                Button("Otvoriť priečinok Import") { try? FileManager.default.createDirectory(at: Store.importDir, withIntermediateDirectories: true); NSWorkspace.shared.open(Store.importDir) }
                Button("Obnoviť") { pending = model.store.pendingImports() }
                Spacer()
                Button("Spýtať sa Brainu") {
                    var c = URLComponents(string: "brain://ask")!
                    c.queryItems = [URLQueryItem(name: "q", value: "Importuj staré faktúry z priečinka Import do Faktúr (faktury.import_pending, potom tabuľka na kontrolu a invoice_import po mojom áno).")]
                    if let u = c.url { NSWorkspace.shared.open(u) }
                }
                Button("Hotovo") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { pending = model.store.pendingImports() }
    }
}
