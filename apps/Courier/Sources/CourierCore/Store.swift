import Foundation
import SQLite3

// MARK: Models

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var imap: ServerConfig
    public var smtp: ServerConfig?
    public var sort: Int
    public init(id: String = UUID().uuidString, email: String, name: String, imap: ServerConfig, smtp: ServerConfig?, sort: Int = 0) {
        self.id = id; self.email = email; self.name = name; self.imap = imap; self.smtp = smtp; self.sort = sort
    }
}

public enum FolderRole: String, Codable, Sendable, CaseIterable {
    case inbox, drafts, sent, junk, trash, archive, all, flagged, other

    public var title: String {
        switch self {
        case .inbox: "Doručené"; case .drafts: "Koncepty"; case .sent: "Odoslané"; case .junk: "Spam"; case .trash: "Kôš"
        case .archive: "Archív"; case .all: "Všetky správy"; case .flagged: "Označené"; case .other: ""
        }
    }
    public var symbol: String {
        switch self {
        case .inbox: "tray"; case .drafts: "doc"; case .sent: "paperplane"; case .junk: "xmark.bin"; case .trash: "trash"
        case .archive: "archivebox"; case .all: "tray.2"; case .flagged: "flag"; case .other: "folder"
        }
    }
    var order: Int { Self.allCases.firstIndex(of: self)! }
}

public struct Folder: Codable, Identifiable, Hashable, Sendable {
    public var accountID: String
    public var path: String          // server name (modified UTF-7)
    public var name: String          // decoded, last path component
    public var delimiter: String?
    public var role: FolderRole
    public var unread: Int
    public var total: Int
    public var selectable: Bool
    public var id: String { accountID + "\u{1}" + path }
    public var displayName: String { role != .other && role.title.isEmpty == false ? role.title : name }
    /// Nesting depth from the delimiter (INBOX children are shown under INBOX).
    public var depth: Int {
        guard let d = delimiter, !d.isEmpty else { return 0 }
        return path.components(separatedBy: d).count - 1
    }
    public var sortKey: (Int, String) { (role == .other ? 100 : role.order, path.lowercased()) }
}

public struct MessageSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var accountID: String
    public var folder: String
    public var uid: UInt32
    public var subject: String
    public var fromName: String
    public var fromAddress: String
    public var to: String
    public var date: Date
    public var seen: Bool
    public var flagged: Bool
    public var answered: Bool
    public var hasAttachments: Bool
    public var snippet: String
    public var threadID: String
    public var category: MailCategory = .people
    public var fromDisplay: String { fromName.isEmpty ? fromAddress : fromName }
    /// Key of the conversation (threads never cross accounts).
    public var threadKey: String { accountID + "\u{1}" + threadID }
}

public enum TicketStatus: String, Codable, Sendable, CaseIterable {
    case open, waiting, done
    public var title: String { switch self { case .open: "Otvorené"; case .waiting: "Čaká sa"; case .done: "Hotovo" } }
    public var symbol: String { switch self { case .open: "circle"; case .waiting: "clock"; case .done: "checkmark.circle.fill" } }
}

/// Local ticket state of a conversation: a status and free tags. Never written to the server.
public struct Ticket: Codable, Hashable, Sendable {
    public var accountID: String
    public var threadID: String
    public var status: TicketStatus?
    public var tags: [String]
    public var updated: Date
    public init(accountID: String, threadID: String, status: TicketStatus? = nil, tags: [String] = [], updated: Date = Date()) {
        self.accountID = accountID; self.threadID = threadID; self.status = status; self.tags = tags; self.updated = updated
    }
    public var key: String { accountID + "\u{1}" + threadID }
}

public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var color: String
    public var id: String { name }
    public init(name: String, color: String) { self.name = name; self.color = color }
}

public struct MessageBody: Codable, Sendable {
    public var text: String?
    public var html: String?
    public var cc: String
    public var attachments: [Attachment]
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: String       // named color, see ProjectColor in the app
    public var symbol: String
    public var sort: Int
    public var sources: [ProjectSource]
    public init(id: String = UUID().uuidString, name: String, color: String = "blue", symbol: String = "folder.fill", sort: Int = 0, sources: [ProjectSource] = []) {
        self.id = id; self.name = name; self.color = color; self.symbol = symbol; self.sort = sort; self.sources = sources
    }
}

/// What feeds a project: a whole mailbox (its inbox), one IMAP folder, or a sender / domain rule across all inboxes.
public struct ProjectSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case account, folder, sender }
    public var kind: Kind
    public var accountID: String?
    public var folder: String?
    public var pattern: String?
    public init(kind: Kind, accountID: String? = nil, folder: String? = nil, pattern: String? = nil) {
        self.kind = kind; self.accountID = accountID; self.folder = folder; self.pattern = pattern
    }
}

// MARK: SQLite

enum SQLValue { case int(Int64), real(Double), text(String), blob(Data), null }

/// The local cache: ~/Library/Application Support/Courier/courier.sqlite (WAL, so the MCP server can read while the app writes).
public final class Store: @unchecked Sendable {
    public static var directory: URL {
        #if os(macOS)
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Courier")
        #else
        let d = URL.applicationSupportDirectory.appendingPathComponent("Courier")
        #endif
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var socketPath: String { directory.appendingPathComponent("courier.sock").path }

    private var db: OpaquePointer?
    /// Sender → category rules set by the user.
    public private(set) var overrides: [String: MailCategory] = [:]
    private let lock = NSRecursiveLock()

    public init(readOnly: Bool = false, path: URL = Store.directory.appendingPathComponent("courier.sqlite")) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MailError.server("SQLite: nedá sa otvoriť \(path.path)")
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly { try migrate() }
    }

    deinit { sqlite3_close(db) }

    func migrate() throws {
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
        CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, email TEXT, name TEXT, imap TEXT, smtp TEXT, sort INT DEFAULT 0);
        CREATE TABLE IF NOT EXISTS folders(account_id TEXT, path TEXT, name TEXT, delimiter TEXT, role TEXT, unread INT, total INT,
            selectable INT, uidvalidity INT DEFAULT 0, PRIMARY KEY(account_id, path));
        CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, account_id TEXT, folder TEXT, uid INT, message_id TEXT,
            subject TEXT, from_name TEXT, from_addr TEXT, to_line TEXT, cc_line TEXT, date REAL, seen INT, flagged INT, answered INT,
            size INT, has_attachments INT, snippet TEXT DEFAULT '', body_text TEXT, body_html TEXT, attachments TEXT, fetched INT DEFAULT 0,
            UNIQUE(account_id, folder, uid));
        CREATE INDEX IF NOT EXISTS messages_folder_date ON messages(account_id, folder, date DESC);
        CREATE INDEX IF NOT EXISTS messages_from ON messages(from_addr);
        CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, name TEXT, color TEXT, symbol TEXT, sort INT, sources TEXT);
        CREATE TABLE IF NOT EXISTS tickets(account_id TEXT, thread_id TEXT, status TEXT, tags TEXT, updated REAL, PRIMARY KEY(account_id, thread_id));
        CREATE TABLE IF NOT EXISTS tags(name TEXT PRIMARY KEY, color TEXT, sort INT DEFAULT 0);
        """)
        let cols = Set(try run("PRAGMA table_info(messages)").map { $0.s("name") })
        for (c, t) in [("in_reply_to", "TEXT"), ("refs", "TEXT"), ("thread_id", "TEXT"), ("category", "TEXT"), ("unsubscribe", "TEXT")] where !cols.contains(c) {
            try exec("ALTER TABLE messages ADD COLUMN \(c) \(t)")
        }
        try exec("CREATE INDEX IF NOT EXISTS messages_thread ON messages(account_id, thread_id)")
        try exec("CREATE INDEX IF NOT EXISTS messages_msgid ON messages(message_id)")
        try migrateOutbox()
        try exec("CREATE TABLE IF NOT EXISTS sender_categories(address TEXT PRIMARY KEY, category TEXT)")
        reloadOverrides()
    }

    // MARK: Low level

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw MailError.server("SQLite: \(msg)")
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> [[String: SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw MailError.server("SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as UInt32: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Bool: sqlite3_bind_int64(st, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Date: sqlite3_bind_double(st, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_text(st, idx, "\(a!)", -1, transient)
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW else { throw MailError.server("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(st, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(st, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(st, c))
                    row[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(st, c), count: n) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    // MARK: Accounts

    public func accounts() -> [Account] {
        ((try? run("SELECT * FROM accounts ORDER BY sort, email")) ?? []).compactMap { r in
            guard let imap: ServerConfig = r.json("imap") else { return nil }
            return Account(id: r.s("id"), email: r.s("email"), name: r.s("name"), imap: imap, smtp: r.json("smtp"), sort: r.i("sort"))
        }
    }

    public func save(_ a: Account) throws {
        try run("INSERT OR REPLACE INTO accounts(id,email,name,imap,smtp,sort) VALUES(?,?,?,?,?,?)",
                [a.id, a.email, a.name, Self.json(a.imap), a.smtp.map(Self.json), a.sort])
    }

    public func deleteAccount(_ id: String) throws {
        try transaction {
            try run("DELETE FROM accounts WHERE id=?", [id])
            try run("DELETE FROM folders WHERE account_id=?", [id])
            try run("DELETE FROM messages WHERE account_id=?", [id])
        }
    }

    // MARK: Folders

    public func folders(account: String? = nil) -> [Folder] {
        let rows = (try? account.map { try run("SELECT * FROM folders WHERE account_id=?", [$0]) } ?? run("SELECT * FROM folders")) ?? []
        return rows.map { r in
            Folder(accountID: r.s("account_id"), path: r.s("path"), name: r.s("name"), delimiter: r.os("delimiter"),
                   role: FolderRole(rawValue: r.s("role")) ?? .other, unread: r.i("unread"), total: r.i("total"), selectable: r.i("selectable") != 0)
        }.sorted { $0.sortKey < $1.sortKey }
    }

    public func replaceFolders(account: String, _ folders: [Folder]) throws {
        try transaction {
            let keep = Set(folders.map(\.path))
            for old in self.folders(account: account) where !keep.contains(old.path) {
                try run("DELETE FROM folders WHERE account_id=? AND path=?", [account, old.path])
                try run("DELETE FROM messages WHERE account_id=? AND folder=?", [account, old.path])
            }
            for f in folders {
                try run("""
                INSERT INTO folders(account_id,path,name,delimiter,role,unread,total,selectable) VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(account_id,path) DO UPDATE SET name=excluded.name, delimiter=excluded.delimiter, role=excluded.role,
                  unread=excluded.unread, total=excluded.total, selectable=excluded.selectable
                """, [account, f.path, f.name, f.delimiter, f.role.rawValue, f.unread, f.total, f.selectable])
            }
        }
    }

    public func uidValidity(account: String, folder: String) -> UInt32 {
        UInt32((try? run("SELECT uidvalidity FROM folders WHERE account_id=? AND path=?", [account, folder]))?.first?.i("uidvalidity") ?? 0)
    }

    public func setUIDValidity(account: String, folder: String, _ v: UInt32) throws {
        try run("UPDATE folders SET uidvalidity=? WHERE account_id=? AND path=?", [v, account, folder])
    }

    public func setCounts(account: String, folder: String, unread: Int, total: Int) throws {
        try run("UPDATE folders SET unread=?, total=? WHERE account_id=? AND path=?", [unread, total, account, folder])
    }

    // MARK: Messages

    public struct HeaderRow {
        public var uid: UInt32, messageID: String, subject: String, from: EmailAddress?, to: String, cc: String, date: Date
        public var seen: Bool, flagged: Bool, answered: Bool, size: Int, hasAttachments: Bool
        public var inReplyTo: String = "", references: [String] = []
        /// List-Unsubscribe as stored (see Unsubscribe.encode); empty when the message has none.
        public var unsubscribe: String = ""
        public var category: MailCategory = .people
        /// Root of the conversation: first References id, else In-Reply-To, else own Message-ID.
        public var threadID: String {
            references.first ?? (inReplyTo.isEmpty ? nil : inReplyTo) ?? (messageID.isEmpty ? "uid-\(uid)-\(subject.hashValue)" : messageID)
        }
    }

    /// "<a@b> <c@d>" → ["a@b", "c@d"], lowercased.
    public static func messageIDs(_ raw: String) -> [String] {
        var out: [String] = []
        var cur: String?
        for ch in raw {
            if ch == "<" { cur = "" } else if ch == ">" { if let c = cur, !c.isEmpty { out.append(c.lowercased()) }; cur = nil } else { cur?.append(ch) }
        }
        if out.isEmpty {
            out = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased() }.filter { $0.contains("@") }
        }
        return out
    }

    /// Upserts headers for one folder window; drops cached messages in [minUID, ∞) that the server no longer has (expunged).
    public func upsertHeaders(account: String, folder: String, _ rows: [HeaderRow], windowStart: UInt32?) throws {
        try transaction {
            for h in rows {
                try run("""
                INSERT INTO messages(account_id,folder,uid,message_id,subject,from_name,from_addr,to_line,cc_line,date,seen,flagged,answered,size,
                  has_attachments,in_reply_to,refs,thread_id,category,unsubscribe)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account_id,folder,uid) DO UPDATE SET seen=excluded.seen, flagged=excluded.flagged, answered=excluded.answered,
                  message_id=excluded.message_id, in_reply_to=excluded.in_reply_to, refs=excluded.refs,
                  unsubscribe=COALESCE(NULLIF(excluded.unsubscribe,''), messages.unsubscribe),
                  category=CASE WHEN messages.category IN ('invites','invoices') THEN messages.category ELSE excluded.category END,
                  thread_id=CASE WHEN messages.refs IS NULL THEN excluded.thread_id ELSE messages.thread_id END
                """, [account, folder, h.uid, h.messageID, h.subject, h.from?.name ?? "", h.from?.address ?? "", h.to, h.cc, h.date,
                      h.seen, h.flagged, h.answered, h.size, h.hasAttachments, h.inReplyTo, h.references.joined(separator: " "), h.threadID,
                      h.category.rawValue, h.unsubscribe])
            }
            if let windowStart {
                let uids = Set(rows.map(\.uid))
                for r in try run("SELECT uid FROM messages WHERE account_id=? AND folder=? AND uid>=?", [account, folder, windowStart])
                where !uids.contains(UInt32(r.i("uid"))) {
                    try run("DELETE FROM messages WHERE account_id=? AND folder=? AND uid=?", [account, folder, r.i("uid")])
                }
            }
        }
    }

    /// Joins conversations whose root id is itself a reply (In-Reply-To without References), and replies that arrived before
    /// their parent: a message takes the thread of the message its thread id points to, a few rounds deep.
    public func fixThreads(account: String) throws {
        for _ in 0..<4 {
            try run("""
            UPDATE messages SET thread_id = (SELECT p.thread_id FROM messages p WHERE p.account_id=messages.account_id
                AND p.message_id=messages.thread_id AND p.thread_id != messages.thread_id LIMIT 1)
            WHERE account_id=? AND EXISTS (SELECT 1 FROM messages p WHERE p.account_id=messages.account_id
                AND p.message_id=messages.thread_id AND p.thread_id != messages.thread_id)
            """, [account])
            if sqlite3_changes(db) == 0 { break }
        }
    }

    public func minUID(account: String, folder: String) -> UInt32? {
        guard let r = (try? run("SELECT min(uid) AS m, count(*) AS c FROM messages WHERE account_id=? AND folder=?", [account, folder]))?.first,
              r.i("c") > 0 else { return nil }
        return UInt32(r.i("m"))
    }

    public func cachedCount(account: String, folder: String) -> Int {
        (try? run("SELECT count(*) AS c FROM messages WHERE account_id=? AND folder=?", [account, folder]))?.first?.i("c") ?? 0
    }

    public func knownUIDs(account: String, folder: String) -> Set<UInt32> {
        Set(((try? run("SELECT uid FROM messages WHERE account_id=? AND folder=?", [account, folder])) ?? []).map { UInt32($0.i("uid")) })
    }

    public func ids(account: String, folder: String, uids: [UInt32]) -> [Int64] {
        guard !uids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: uids.count).joined(separator: ",")
        return ((try? run("SELECT id FROM messages WHERE account_id=? AND folder=? AND uid IN (\(marks))", [account, folder] + uids.map { $0 as Any? })) ?? [])
            .map { Int64($0.i("id")) }
    }

    /// Unread mail from people in all inboxes (the Dock badge).
    public func unreadPeople() -> Int {
        unifiedInbox(unreadOnly: true, limit: 5000).filter { $0.category == .people }.count
    }

    public func clearFolder(account: String, folder: String) throws {
        try run("DELETE FROM messages WHERE account_id=? AND folder=?", [account, folder])
    }

    static let summaryColumns = "id,account_id,folder,uid,subject,from_name,from_addr,to_line,date,seen,flagged,answered,has_attachments,snippet,thread_id,category"

    func summary(_ r: [String: SQLValue]) -> MessageSummary {
        MessageSummary(id: Int64(r.i("id")), accountID: r.s("account_id"), folder: r.s("folder"), uid: UInt32(r.i("uid")), subject: r.s("subject"),
                       fromName: r.s("from_name"), fromAddress: r.s("from_addr"), to: r.s("to_line"),
                       date: Date(timeIntervalSince1970: r.d("date")), seen: r.i("seen") != 0, flagged: r.i("flagged") != 0,
                       answered: r.i("answered") != 0, hasAttachments: r.i("has_attachments") != 0, snippet: r.s("snippet"),
                       threadID: r.os("thread_id") ?? "id-\(r.i("id"))",
                       category: overrides[r.s("from_addr").lowercased()] ?? r.os("category").flatMap(MailCategory.init) ?? .people)
    }

    public func messages(account: String, folder: String, limit: Int = 500) -> [MessageSummary] {
        ((try? run("SELECT \(Self.summaryColumns) FROM messages WHERE account_id=? AND folder=? ORDER BY date DESC LIMIT ?",
                   [account, folder, limit])) ?? []).map(summary)
    }

    /// Messages of a project: its mailboxes' inboxes, its folders, and inbox messages from its senders / domains.
    public func messages(project: Project, unreadOnly: Bool = false, limit: Int = 500) -> [MessageSummary] {
        var clauses: [String] = []
        var args: [Any?] = []
        let inbox = "folder IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role='inbox')"
        for s in project.sources {
            switch s.kind {
            case .account: clauses.append("(account_id=? AND \(inbox))"); args.append(s.accountID)
            case .folder: clauses.append("(account_id=? AND folder=?)"); args += [s.accountID, s.folder]
            case .sender:
                guard let p = s.pattern?.trimmingCharacters(in: .whitespaces).lowercased(), !p.isEmpty else { continue }
                clauses.append("(lower(from_addr) LIKE ? AND \(inbox))"); args.append("%\(p)%")
            }
        }
        guard !clauses.isEmpty else { return [] }
        let unread = unreadOnly ? " AND seen=0" : ""
        return ((try? run("SELECT \(Self.summaryColumns) FROM messages WHERE (\(clauses.joined(separator: " OR ")))\(unread) ORDER BY date DESC LIMIT ?",
                          args + [limit])) ?? []).map(summary)
    }

    /// All inboxes together.
    /// Every account's folder with this role together (all drafts, all sent, …), newest first.
    public func unified(role: FolderRole, limit: Int = 500) -> [MessageSummary] {
        ((try? run("""
        SELECT \(Self.summaryColumns) FROM messages WHERE folder IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role=?)
        ORDER BY date DESC LIMIT ?
        """, [role.rawValue, limit])) ?? []).map(summary)
    }

    public func unifiedInbox(unreadOnly: Bool = false, limit: Int = 500) -> [MessageSummary] {
        ((try? run("""
        SELECT \(Self.summaryColumns) FROM messages WHERE folder IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role='inbox')
        \(unreadOnly ? "AND seen=0" : "") ORDER BY date DESC LIMIT ?
        """, [limit])) ?? []).map(summary)
    }

    public func search(_ q: String, account: String? = nil, limit: Int = 100) -> [MessageSummary] {
        let like = "%\(q.lowercased())%"
        var sql = """
        SELECT \(Self.summaryColumns) FROM messages WHERE (lower(subject) LIKE ? OR lower(from_name) LIKE ? OR lower(from_addr) LIKE ?
          OR lower(to_line) LIKE ? OR lower(snippet) LIKE ? OR lower(coalesce(body_text,'')) LIKE ? OR lower(coalesce(attachments,'')) LIKE ?)
        """
        var args: [Any?] = [like, like, like, like, like, like, like]
        if let account { sql += " AND account_id=?"; args.append(account) }
        sql += " ORDER BY date DESC LIMIT ?"
        args.append(limit)
        return ((try? run(sql, args)) ?? []).map(summary)
    }

    public func message(id: Int64) -> MessageSummary? {
        (try? run("SELECT \(Self.summaryColumns) FROM messages WHERE id=?", [id]))?.first.map(summary)
    }

    public func message(messageID: String, account: String) -> MessageSummary? {
        (try? run("SELECT \(Self.summaryColumns) FROM messages WHERE account_id=? AND message_id=? LIMIT 1", [account, messageID.lowercased()]))?.first.map(summary)
    }

    /// Drops the cached copies of a message from a folder by its Message-ID (a draft that was just sent),
    /// so the list does not show it until the next sync of that folder.
    public func deleteMessages(account: String, folder: String, messageID: String) throws {
        guard !messageID.isEmpty else { return }
        try run("DELETE FROM messages WHERE account_id=? AND folder=? AND message_id=?", [account, folder, messageID.lowercased()])
    }

    /// The draft (in the account's Drafts) that a message about to be sent was written from: the one with the same
    /// subject and the same To addresses. Only when exactly one draft matches, so nothing else gets removed.
    public func matchingDraft(account: String, subject: String, to: [EmailAddress]) -> MessageSummary? {
        guard let drafts = folders(account: account).first(where: { $0.role == .drafts }), !to.isEmpty else { return nil }
        let want = Set(to.map { $0.address.lowercased() })
        let rows = ((try? run("SELECT \(Self.summaryColumns) FROM messages WHERE account_id=? AND folder=?", [account, drafts.path])) ?? []).map(summary)
        let hits = rows.filter {
            $0.subject.trimmingCharacters(in: .whitespaces) == subject.trimmingCharacters(in: .whitespaces)
                && Set(MIME.parseAddresses($0.to).map { $0.address.lowercased() }) == want
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Message-ID and References of a message, for replying.
    public func threadHeaders(id: Int64) -> (messageID: String, references: [String]) {
        guard let r = (try? run("SELECT message_id, refs FROM messages WHERE id=?", [id]))?.first else { return ("", []) }
        return (r.s("message_id"), r.s("refs").split(separator: " ").map(String.init))
    }

    public func body(id: Int64) -> MessageBody? {
        guard let r = (try? run("SELECT body_text, body_html, cc_line, attachments, fetched FROM messages WHERE id=?", [id]))?.first,
              r.i("fetched") != 0 else { return nil }
        return MessageBody(text: r.os("body_text"), html: r.os("body_html"), cc: r.s("cc_line"), attachments: r.json("attachments") ?? [])
    }

    public func saveBody(id: Int64, _ m: ParsedMessage) throws {
        try run("UPDATE messages SET body_text=?, body_html=?, attachments=?, snippet=?, has_attachments=?, fetched=1 WHERE id=?",
                [m.text, m.html, Self.json(m.attachments), m.snippet, !m.attachments.isEmpty, id])
    }

    // MARK: Raw messages & attachments

    public static var rawDirectory: URL {
        let d = directory.appendingPathComponent("Messages")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static func rawURL(_ id: Int64) -> URL { rawDirectory.appendingPathComponent("\(id).eml") }

    /// Attachment names known for a message: from the downloaded body, or from BODYSTRUCTURE before that.
    public func attachments(id: Int64) -> [Attachment] {
        (try? run("SELECT attachments FROM messages WHERE id=?", [id]))?.first?.json("attachments") ?? []
    }

    public func setAttachmentsMeta(account: String, folder: String, uid: UInt32, _ list: [Attachment]) throws {
        try run("UPDATE messages SET attachments=?, has_attachments=? WHERE account_id=? AND folder=? AND uid=? AND fetched=0",
                [Self.json(list), !list.isEmpty, account, folder, uid])
    }

    public struct AttachmentHit: Identifiable, Hashable, Sendable {
        public var message: MessageSummary
        public var index: Int
        public var attachment: Attachment
        public var id: String { "\(message.id)-\(index)" }
    }

    /// Every known attachment (newest first), optionally filtered by file name, sender or subject.
    public func attachmentHits(_ q: String = "", account: String? = nil, limit: Int = 500) -> [AttachmentHit] {
        var sql = "SELECT \(Self.summaryColumns), attachments FROM messages WHERE has_attachments=1 AND attachments IS NOT NULL AND attachments != '[]'"
        var args: [Any?] = []
        let needle = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            sql += " AND (lower(attachments) LIKE ? OR lower(from_addr) LIKE ? OR lower(from_name) LIKE ? OR lower(subject) LIKE ?)"
            args += Array(repeating: "%\(needle)%", count: 4)
        }
        if let account { sql += " AND account_id=?"; args.append(account) }
        sql += " ORDER BY date DESC LIMIT ?"
        args.append(limit)
        var out: [AttachmentHit] = []
        for r in (try? run(sql, args)) ?? [] {
            let m = summary(r)
            let list: [Attachment] = r.json("attachments") ?? []
            for (i, a) in list.enumerated() {
                // With a query, list only the files that match (unless the sender or subject matched).
                if !needle.isEmpty, !a.filename.lowercased().contains(needle),
                   !(m.fromAddress + m.fromName + m.subject).lowercased().contains(needle) { continue }
                out.append(AttachmentHit(message: m, index: i, attachment: a))
            }
        }
        return out
    }

    /// Stored List-Unsubscribe of a message: nil = never fetched (older cache), "" = the message has none.
    public func unsubscribeHeader(id: Int64) -> String? {
        (try? run("SELECT unsubscribe FROM messages WHERE id=?", [id]))?.first?.os("unsubscribe")
    }
    public func setUnsubscribeHeader(id: Int64, _ v: String) throws { try run("UPDATE messages SET unsubscribe=? WHERE id=?", [v, id]) }

    /// Inbox messages from one sender (newest first), e.g. to archive a newsletter after unsubscribing.
    public func messages(from address: String, role: FolderRole = .inbox, limit: Int = 2000) -> [MessageSummary] {
        ((try? run("""
        SELECT \(Self.summaryColumns) FROM messages WHERE lower(from_addr)=lower(?)
          AND folder IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role=?)
        ORDER BY date DESC LIMIT ?
        """, [address, role.rawValue, limit])) ?? []).map(summary)
    }

    public func setSeen(id: Int64, _ seen: Bool) throws { try run("UPDATE messages SET seen=? WHERE id=?", [seen, id]) }

    public func unfetched(account: String, folder: String, limit: Int, maxSize: Int) -> [MessageSummary] {
        ((try? run("SELECT \(Self.summaryColumns) FROM messages WHERE account_id=? AND folder=? AND fetched=0 AND size<? ORDER BY date DESC LIMIT ?",
                   [account, folder, maxSize, limit])) ?? []).map(summary)
    }

    // MARK: Categories

    public func reloadOverrides() {
        overrides = Dictionary(((try? run("SELECT address, category FROM sender_categories")) ?? []).compactMap { r in
            MailCategory(rawValue: r.s("category")).map { (r.s("address"), $0) }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// "This sender is …": applies to all their mail, now and later. nil removes the rule.
    public func setSenderCategory(_ address: String, _ c: MailCategory?) throws {
        let a = address.lowercased()
        if let c { try run("INSERT OR REPLACE INTO sender_categories(address, category) VALUES(?,?)", [a, c.rawValue]) }
        else { try run("DELETE FROM sender_categories WHERE address=?", [a]) }
        reloadOverrides()
    }

    public func setCategory(account: String, folder: String, uid: UInt32, _ c: MailCategory) throws {
        try run("UPDATE messages SET category=? WHERE account_id=? AND folder=? AND uid=?", [c.rawValue, account, folder, uid])
    }

    /// Messages synced before categories existed.
    public func unclassified(account: String, folder: String, limit: Int) -> [UInt32] {
        ((try? run("SELECT uid FROM messages WHERE account_id=? AND folder=? AND category IS NULL LIMIT ?", [account, folder, limit])) ?? [])
            .map { UInt32($0.i("uid")) }
    }

    // MARK: Threads

    /// Whole conversation, oldest first, across the account's folders (trash and spam left out).
    public func thread(account: String, id: String) -> [MessageSummary] {
        ((try? run("""
        SELECT \(Self.summaryColumns) FROM messages WHERE account_id=? AND thread_id=?
          AND folder NOT IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role IN ('trash','junk'))
        ORDER BY date ASC
        """, [account, id])) ?? []).map(summary)
    }

    /// Message count and unread count per conversation (by threadKey).
    public func threadStats(_ keys: Set<String>) -> [String: (count: Int, unread: Int)] {
        guard !keys.isEmpty else { return [:] }
        var out: [String: (Int, Int)] = [:]
        let ids = Array(Set(keys.compactMap { $0.split(separator: "\u{1}", maxSplits: 1).last.map(String.init) }))
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in (try? run("""
            SELECT account_id, thread_id, count(*) AS c, sum(1 - seen) AS u FROM messages WHERE thread_id IN (\(marks))
              AND folder NOT IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role IN ('trash','junk'))
            GROUP BY account_id, thread_id
            """, chunk)) ?? [] {
                let k = r.s("account_id") + "\u{1}" + r.s("thread_id")
                if keys.contains(k) { out[k] = (r.i("c"), r.i("u")) }
            }
        }
        return out.mapValues { (count: $0.0, unread: $0.1) }
    }

    // MARK: Tickets & tags

    func ticket(_ r: [String: SQLValue]) -> Ticket {
        Ticket(accountID: r.s("account_id"), threadID: r.s("thread_id"), status: r.os("status").flatMap(TicketStatus.init),
               tags: r.json("tags") ?? [], updated: Date(timeIntervalSince1970: r.d("updated")))
    }

    public func tickets() -> [String: Ticket] {
        Dictionary(((try? run("SELECT * FROM tickets")) ?? []).map(ticket).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func save(_ t: Ticket) throws {
        if t.status == nil && t.tags.isEmpty {
            try run("DELETE FROM tickets WHERE account_id=? AND thread_id=?", [t.accountID, t.threadID])
        } else {
            try run("INSERT OR REPLACE INTO tickets(account_id,thread_id,status,tags,updated) VALUES(?,?,?,?,?)",
                    [t.accountID, t.threadID, t.status?.rawValue, Self.json(t.tags), Date()])
        }
    }

    /// Newest message of every conversation that has this status / tag.
    public func messages(status: TicketStatus? = nil, tag: String? = nil, limit: Int = 500) -> [MessageSummary] {
        var sql = "SELECT \(Self.summaryColumns.split(separator: ",").map { "m.\($0)" }.joined(separator: ",")) FROM messages m JOIN tickets t ON m.account_id=t.account_id AND m.thread_id=t.thread_id WHERE 1=1"
        var args: [Any?] = []
        if let status { sql += " AND t.status=?"; args.append(status.rawValue) }
        if let tag { sql += " AND EXISTS (SELECT 1 FROM json_each(t.tags) WHERE value=?)"; args.append(tag) }
        sql += " ORDER BY m.date DESC LIMIT ?"
        args.append(limit * 5)
        return ((try? run(sql, args)) ?? []).map(summary)
    }

    /// A new message from someone else in a waiting / done conversation opens it again.
    public func reopenTickets(account: String, me: String) throws {
        try run("""
        UPDATE tickets SET status='open', updated=? WHERE account_id=? AND status IN ('waiting','done') AND EXISTS (
          SELECT 1 FROM messages m WHERE m.account_id=tickets.account_id AND m.thread_id=tickets.thread_id
            AND m.date > tickets.updated AND lower(m.from_addr) != lower(?))
        """, [Date(), account, me])
    }

    public func tags() -> [Tag] {
        ((try? run("SELECT * FROM tags ORDER BY sort, name")) ?? []).map { Tag(name: $0.s("name"), color: $0.s("color")) }
    }

    public func save(_ t: Tag) throws { try run("INSERT OR REPLACE INTO tags(name,color) VALUES(?,?)", [t.name, t.color]) }

    /// Renames a tag everywhere (merges into an existing tag of that name).
    public func renameTag(_ old: String, to new: String) throws {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old else { return }
        let color = tags().first { $0.name == old }?.color ?? "blue"
        try run("DELETE FROM tags WHERE name=?", [old])
        if !tags().contains(where: { $0.name == n }) { try save(Tag(name: n, color: color)) }
        for t in tickets().values where t.tags.contains(old) {
            var t = t
            t.tags = t.tags.map { $0 == old ? n : $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            try save(t)
        }
    }

    public func deleteTag(_ name: String) throws {
        try run("DELETE FROM tags WHERE name=?", [name])
        for t in tickets().values where t.tags.contains(name) {
            var t = t; t.tags.removeAll { $0 == name }; try save(t)
        }
    }

    public func unreadCount(project: Project) -> Int { messages(project: project, unreadOnly: true, limit: 10_000).count }

    // MARK: Projects

    public func projects() -> [Project] {
        ((try? run("SELECT * FROM projects ORDER BY sort, name")) ?? []).map { r in
            Project(id: r.s("id"), name: r.s("name"), color: r.s("color"), symbol: r.s("symbol"), sort: r.i("sort"), sources: r.json("sources") ?? [])
        }
    }

    public func save(_ p: Project) throws {
        try run("INSERT OR REPLACE INTO projects(id,name,color,symbol,sort,sources) VALUES(?,?,?,?,?,?)",
                [p.id, p.name, p.color, p.symbol, p.sort, Self.json(p.sources)])
    }

    public func deleteProject(_ id: String) throws { try run("DELETE FROM projects WHERE id=?", [id]) }

    static func json<T: Encodable>(_ v: T) -> String { String(decoding: (try? JSONEncoder().encode(v)) ?? Data(), as: UTF8.self) }
}

extension Dictionary where Key == String, Value == SQLValue {
    func s(_ k: String) -> String { os(k) ?? "" }
    func os(_ k: String) -> String? {
        switch self[k] { case .text(let t): return t; case .int(let i): return String(i); case .real(let d): return String(d); default: return nil }
    }
    func i(_ k: String) -> Int {
        switch self[k] { case .int(let i): return Int(i); case .real(let d): return Int(d); case .text(let t): return Int(t) ?? 0; default: return 0 }
    }
    func d(_ k: String) -> Double {
        switch self[k] { case .int(let i): return Double(i); case .real(let d): return d; default: return 0 }
    }
    func json<T: Decodable>(_ k: String) -> T? { os(k).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) } }
}

// MARK: Address book from mail history

public struct KnownAddress: Hashable, Sendable {
    public var name: String
    public var address: String
    public var sentTo: Int        // how often the user wrote to them
    public var received: Int      // how often they wrote
}

extension Store {
    /// Everyone the user has written to (weighted most) or received mail from.
    public func knownAddresses(myAddresses: Set<String>) -> [KnownAddress] {
        var book: [String: KnownAddress] = [:]
        for r in (try? run("SELECT from_name, from_addr, count(*) AS c FROM messages WHERE from_addr != '' GROUP BY lower(from_addr)")) ?? [] {
            let a = r.s("from_addr")
            let k = a.lowercased()
            guard !myAddresses.contains(k), !k.contains("noreply"), !k.contains("no-reply") else { continue }
            book[k] = KnownAddress(name: r.s("from_name"), address: a, sentTo: 0, received: r.i("c"))
        }
        let sentRows = (try? run("""
        SELECT to_line, cc_line FROM messages WHERE folder IN (SELECT path FROM folders f WHERE f.account_id=messages.account_id AND f.role='sent')
        """)) ?? []
        for r in sentRows {
            for a in MIME.parseAddresses(r.s("to_line")) + MIME.parseAddresses(r.s("cc_line")) {
                let k = a.address.lowercased()
                guard k.contains("@"), !myAddresses.contains(k) else { continue }
                var e = book[k] ?? KnownAddress(name: a.name, address: a.address, sentTo: 0, received: 0)
                e.sentTo += 1
                if e.name.isEmpty { e.name = a.name }
                book[k] = e
            }
        }
        return Array(book.values)
    }

    /// Everyone who appears anywhere in the mail (From, To, Cc of every message), for the address book.
    public func allContacts(myAddresses: Set<String>) -> [MailContact] {
        var book: [String: MailContact] = [:]
        func add(_ name: String, _ address: String, from: Int, to: Int, last: Double) {
            let k = address.lowercased()
            guard k.contains("@"), !myAddresses.contains(k) else { return }
            var e = book[k] ?? MailContact(name: "", address: address, fromCount: 0, toCount: 0, lastDate: .distantPast)
            if e.name.isEmpty || (!name.isEmpty && name.lowercased() != k && e.name.lowercased() == k) { e.name = name }
            e.fromCount += from
            e.toCount += to
            let d = Date(timeIntervalSince1970: last)
            if d > e.lastDate { e.lastDate = d }
            book[k] = e
        }
        for r in (try? run("SELECT max(from_name) AS n, from_addr, count(*) AS c, max(date) AS d FROM messages WHERE from_addr != '' GROUP BY lower(from_addr)")) ?? [] {
            add(r.s("n"), r.s("from_addr"), from: r.i("c"), to: 0, last: r.d("d"))
        }
        // Same recipient lines repeat a lot (threads, newsletters): parse each distinct one once.
        for r in (try? run("SELECT to_line, coalesce(cc_line,'') AS cc_line, count(*) AS c, max(date) AS d FROM messages GROUP BY to_line, cc_line")) ?? [] {
            for a in MIME.parseAddresses(r.s("to_line")) + MIME.parseAddresses(r.s("cc_line")) {
                add(a.name, a.address, from: 0, to: r.i("c"), last: r.d("d"))
            }
        }
        return Array(book.values)
    }

    /// Messages sent by or to an address, newest first.
    public func messages(involving address: String, limit: Int = 300) -> [MessageSummary] {
        let a = address.lowercased()
        let like = "%\(a)%"
        return ((try? run("""
        SELECT \(Self.summaryColumns) FROM messages WHERE lower(from_addr)=? OR lower(to_line) LIKE ? OR lower(coalesce(cc_line,'')) LIKE ?
        ORDER BY date DESC LIMIT ?
        """, [a, like, like, limit])) ?? []).map(summary)
    }
}

public struct MailContact: Hashable, Sendable, Identifiable {
    public var name: String
    public var address: String
    public var fromCount: Int     // messages they sent
    public var toCount: Int       // messages they were a recipient of
    public var lastDate: Date
    public var id: String { address.lowercased() }
    public var display: String { name.isEmpty ? address : name }
    public var total: Int { fromCount + toCount }
}
