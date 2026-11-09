import Foundation

/// Backups to iCloud Drive › Financie › Záloha databázy: a consistent copy of the database once a day (app start and every few
/// hours while it runs) or on demand. Keeps 30 daily and 12 monthly copies, like Faktúry.
public enum Backup {
    public static var root: URL {
        if let d = ProcessInfo.processInfo.environment["FINANCIE_BACKUP_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Financie")
    }
    static var dbDir: URL { root.appendingPathComponent("Záloha databázy") }

    @discardableResult
    public static func run(_ store: Store) throws -> URL {
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let file = dbDir.appendingPathComponent("financie-\(Day.today).sqlite")
        let tmp = dbDir.appendingPathComponent(".financie-\(UUID().uuidString).sqlite")
        try store.db.backup(to: tmp.path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: tmp, to: file)
        store.setMeta("last_backup", Day.now)
        prune()
        return file
    }

    public static func last(_ store: Store) -> String? { store.meta("last_backup") }

    public static func runIfDue(_ store: Store) {
        if let l = last(store), l.prefix(10) == Day.today.prefix(10) { return }
        _ = try? run(store)
    }

    /// 30 newest daily copies plus the first copy of each of the last 12 months.
    static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dbDir.path).filter({ $0.hasPrefix("financie-") && $0.hasSuffix(".sqlite") }).sorted(by: >)
        else { return }
        var keep = Set(files.prefix(30))
        var months: [String: String] = [:]
        for f in files { let m = String(f.dropFirst(9).prefix(7)); months[m] = min(months[m] ?? f, f) }
        for m in months.keys.sorted(by: >).prefix(12) { keep.insert(months[m]!) }
        for f in files where !keep.contains(f) { try? FileManager.default.removeItem(at: dbDir.appendingPathComponent(f)) }
    }
}
