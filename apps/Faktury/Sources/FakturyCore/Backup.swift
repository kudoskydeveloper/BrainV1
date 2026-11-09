import Foundation

/// Backups to iCloud Drive (~/Library/Mobile Documents/com~apple~CloudDocs/Faktury): a consistent copy of the database after
/// every issued document and once a day, plus every PDF under Faktury/<subjekt>/<rok>/. Keeps 30 daily and 12 monthly copies.
public enum Backup {
    public static var root: URL {
        if let d = ProcessInfo.processInfo.environment["FAKTURY_BACKUP_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Faktury")
    }
    static var dbDir: URL { root.appendingPathComponent("Záloha databázy") }

    static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    /// Copy of an issued PDF where the accountant (and I) can find it.
    public static func mirror(pdf path: String, company: Company, issueDate: String) {
        let year = String(issueDate.prefix(4))
        let dir = root.appendingPathComponent(safe(company.shortName)).appendingPathComponent(year)
        let src = URL(fileURLWithPath: path)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: src, to: dst) }
    }

    @discardableResult
    public static func run(_ store: Store, reason: String) throws -> URL {
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let file = dbDir.appendingPathComponent("faktury-\(f.string(from: Date())).sqlite")
        let tmp = dbDir.appendingPathComponent(".faktury-\(UUID().uuidString).sqlite")
        try store.db.backup(to: tmp.path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: tmp, to: file)
        try? store.db.run("INSERT INTO meta(key, value) VALUES ('last_backup', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [Day.now])
        try? store.audit("backup", nil, reason, after: "\"\(file.lastPathComponent)\"")
        prune()
        return file
    }

    public static func lastBackup(_ store: Store) -> String? {
        (try? store.db.run("SELECT value FROM meta WHERE key = 'last_backup'").first?["value"]?.string) ?? nil
    }

    /// Once a day (on app start and every few hours while it runs).
    public static func runIfDue(_ store: Store) {
        if let last = lastBackup(store), last.prefix(10) == Day.now.prefix(10) { return }
        _ = try? run(store, reason: "daily")
    }

    static func afterIssue(_ store: Store, invoice: Invoice, company: Company) {
        if let p = invoice.pdfPath { mirror(pdf: p, company: company, issueDate: invoice.issueDate) }
        _ = try? run(store, reason: "after_issue")
    }

    /// 30 newest daily copies plus the first copy of each of the last 12 months.
    static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dbDir.path).filter({ $0.hasPrefix("faktury-") && $0.hasSuffix(".sqlite") }).sorted(by: >)
        else { return }
        var keep = Set(files.prefix(30))
        var months: [String: String] = [:]
        for f in files { let m = String(f.dropFirst(8).prefix(7)); months[m] = min(months[m] ?? f, f) }
        for m in months.keys.sorted(by: >).prefix(12) { keep.insert(months[m]!) }
        for f in files where !keep.contains(f) { try? FileManager.default.removeItem(at: dbDir.appendingPathComponent(f)) }
    }
}

/// Monthly export for the accountant: a folder with the PDFs and a CSV (one row per document, VAT per rate).
public enum AccountantExport {
    public static func export(_ store: Store, companyId: Int64, month: String, to base: URL) throws -> URL {
        guard let c = store.company(companyId) else { throw FakturyError("Subjekt neexistuje.") }
        let docs = store.invoices(Store.Filter(companyId: companyId, status: .issued)).filter { $0.issueDate.hasPrefix(month) }
            + store.invoices(Store.Filter(companyId: companyId, status: .cancelled)).filter { $0.issueDate.hasPrefix(month) }
        let dir = base.appendingPathComponent("\(Backup.safe(c.shortName)) \(month)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var csv = "Doklad;Číslo;Stav;Vystavená;Dodanie;Splatnosť;Odberateľ;IČO;DIČ;IČ DPH;Režim DPH;Základ 23 %;DPH 23 %;Základ 19 %;DPH 19 %;Základ 5 %;DPH 5 %;Základ bez DPH;Spolu;Uhradené;Dátum úhrady;K faktúre\n"
        func cell(_ s: String) -> String { s.contains(";") || s.contains("\"") || s.contains("\n") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        for i in docs.sorted(by: { ($0.number ?? "") < ($1.number ?? "") }) {
            let g = i.totals.groups
            func base(_ r: Double) -> String { g.first { $0.rate == r && i.vatMode.chargesVat }.map { Money.plain($0.baseCents) } ?? "" }
            func vat(_ r: Double) -> String { g.first { $0.rate == r && i.vatMode.chargesVat }.map { Money.plain($0.vatCents) } ?? "" }
            let zero = i.vatMode.chargesVat ? "" : Money.plain(i.subtotalCents)
            let row = [i.kind.title, i.number ?? "", i.status == .cancelled ? "zrušená" : "vystavená", Day.sk(i.issueDate), Day.sk(i.deliveryDate), Day.sk(i.dueDate),
                       i.client.name, i.client.ico, i.client.dic, i.client.icDph, i.vatMode.label, base(23), vat(23), base(19), vat(19), base(5), vat(5), zero,
                       Money.plain(i.totalCents), Money.plain(i.paidCents), i.paidAt.map(Day.sk) ?? "", i.creditsNumber ?? ""]
            csv += row.map(cell).joined(separator: ";") + "\n"
            if let p = i.pdfPath, FileManager.default.fileExists(atPath: p) {
                let dst = dir.appendingPathComponent(URL(fileURLWithPath: p).lastPathComponent)
                if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(atPath: p, toPath: dst.path) }
            }
        }
        try Data(("\u{FEFF}" + csv).utf8).write(to: dir.appendingPathComponent("prehlad-\(month).csv"))
        try? store.audit("export", companyId, "accountant", after: "\"\(month)\"")
        return dir
    }
}
