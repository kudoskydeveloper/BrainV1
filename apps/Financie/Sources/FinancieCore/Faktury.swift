import Foundation

/// The link to Faktúry: its database is only ever read. Each subject (firm or sole trader) gets a business wallet with a bank
/// account for its IBAN; later its invoices become expected income and their payments transactions (phase 2).
public enum FakturyLink {
    public static var databasePath: String {
        if let p = ProcessInfo.processInfo.environment["FAKTURY_DB"] { return p }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Faktury/faktury.sqlite").path
    }

    public struct Company: Hashable {
        public let id: Int64
        public let name: String
        public let iban: String
        public let archived: Bool
    }

    /// Subjects in Faktúry (empty when Faktúry isn't installed).
    public static func companies(path: String = databasePath) -> [Company] {
        guard FileManager.default.fileExists(atPath: path), let db = try? DB(path: path, readOnly: true) else { return [] }
        let rows = (try? db.run("SELECT id, name, archived, json_extract(data, '$.iban') AS iban FROM companies ORDER BY id")) ?? []
        return rows.map { Company(id: $0["id"]?.int64 ?? 0, name: $0["name"]?.string ?? "", iban: $0["iban"]?.string ?? "", archived: $0["archived"]?.int == 1) }
    }

    /// Creates a business wallet (with a bank account for the subject's IBAN) for every subject that doesn't have one yet.
    /// Returns the new wallets. Renames follow Faktúry; a wallet is never deleted from here.
    @discardableResult
    public static func sync(_ store: Store, path: String = databasePath) throws -> [Wallet] {
        let linked = Dictionary(store.wallets(includeArchived: true).compactMap { w in w.fakturyCompanyId.map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
        var made: [Wallet] = []
        for c in companies(path: path) where !c.archived {
            if var w = linked[c.id] {
                if w.name != c.name { w.name = c.name; try store.saveWallet(w) }
                continue
            }
            let w = try store.saveWallet(Wallet(name: c.name, kind: .business, fakturyCompanyId: c.id))
            var a = Account(walletId: w.id, name: "Bežný účet", type: .bank)
            a.iban = c.iban
            try store.saveAccount(a)
            made.append(w)
        }
        return made
    }
}
