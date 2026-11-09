import Foundation

/// Talks to the IMAP servers and keeps the Store up to date. One connection per account, reused and reopened on failure.
public actor MailSync {
    /// Outbox items being sent right now (see flushOutbox).
    var sending: Set<String> = []
    public let store: Store
    private var clients: [String: IMAPClient] = [:]
    /// Messages that arrived in an inbox since the last drain (for notifications).
    private var arrived: [Int64] = []

    public func drainArrived() -> [Int64] { defer { arrived = [] }; return arrived }

    public init(store: Store) { self.store = store }

    /// Opens a connection and logs in, without saving anything. Used to verify a new account.
    public static func connect(_ cfg: ServerConfig, secret: String) async throws -> IMAPClient {
        let c = try await IMAPClient(host: cfg.host, port: cfg.port, security: cfg.security)
        switch cfg.auth {
        case .password: try await c.login(user: cfg.username, password: secret)
        case .oauth2: try await c.loginOAuth(user: cfg.username, accessToken: secret)
        }
        return c
    }

    func client(_ a: Account) async throws -> IMAPClient {
        if let c = clients[a.id] {
            if (try? await c.run("NOOP")) != nil { return c }
            clients[a.id] = nil
        }
        guard let secret = Keychain.get(a.id) else { throw MailError.auth("v Keychaine chýba heslo pre \(a.email)") }
        let c = try await Self.connect(a.imap, secret: secret)
        clients[a.id] = c
        return c
    }

    // One IMAP command at a time per connection: the actor is reentrant at every await, so without this a background
    // backfill and a click in the UI would interleave commands on the same socket.
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private func acquire(_ id: String) async {
        if busy.contains(id) {
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        } else {
            busy.insert(id)
        }
    }

    private func release(_ id: String) {
        if var w = waiters[id], !w.isEmpty {
            let next = w.removeFirst()
            waiters[id] = w
            next.resume()
        } else {
            busy.remove(id)
        }
    }

    /// Runs `body` with the account's connection, exclusively; on a connection error reconnects once and retries.
    public func with<T>(_ a: Account, _ body: (IMAPClient) async throws -> T) async throws -> T {
        await acquire(a.id)
        defer { release(a.id) }
        do { return try await body(try await client(a)) } catch MailError.connection {
            clients[a.id] = nil
            return try await body(try await client(a))
        }
    }

    public func disconnect(_ accountID: String) async {
        if let c = clients.removeValue(forKey: accountID) { await c.logout() }
    }

    // MARK: Folders

    public func syncFolders(_ a: Account) async throws {
        let folders: [Folder] = try await with(a) { c in
            let listed = try await c.list()
            var out: [Folder] = []
            var marked = Set<String>()   // folders whose role the server states (SPECIAL-USE)
            for l in listed {
                let selectable = !l.attributes.contains("\\noselect") && !l.attributes.contains("\\nonexistent")
                let decoded = ModifiedUTF7.decode(l.path)
                let name = l.delimiter.flatMap { d in d.isEmpty ? nil : decoded.components(separatedBy: d).last } ?? decoded
                var f = Folder(accountID: a.id, path: l.path, name: name, delimiter: l.delimiter, role: Self.role(l, name: name),
                               unread: 0, total: 0, selectable: selectable)
                if selectable, let s = try? await c.status(l.path) { f.unread = s.unseen; f.total = s.messages }
                if Self.specialUse(l) != nil { marked.insert(l.path) }
                out.append(f)
            }
            return Self.dedupeRoles(out, marked: marked)
        }
        try store.replaceFolders(account: a.id, folders)
    }

    /// The role the server states with a SPECIAL-USE attribute, if any.
    static func specialUse(_ l: IMAPClient.ListedFolder) -> FolderRole? {
        let a = l.attributes
        if a.contains("\\sent") { return .sent }
        if a.contains("\\drafts") { return .drafts }
        if a.contains("\\junk") { return .junk }
        if a.contains("\\trash") { return .trash }
        if a.contains("\\archive") { return .archive }
        if a.contains("\\all") { return .all }
        if a.contains("\\flagged") { return .flagged }
        return nil
    }

    /// SPECIAL-USE attributes first, then common names (English and Slovak/Czech) of the last path component.
    static func role(_ l: IMAPClient.ListedFolder, name: String) -> FolderRole {
        if l.path.uppercased() == "INBOX" { return .inbox }
        if let r = specialUse(l) { return r }
        let n = name.lowercased()
        let names: [(FolderRole, [String])] = [
            (.sent, ["sent", "sent items", "sent messages", "sent mail", "odoslané", "odoslane", "odeslané", "odeslana pošta", "odeslaná pošta"]),
            (.drafts, ["drafts", "draft", "koncepty", "rozpracované"]),
            (.junk, ["spam", "junk", "junk e-mail", "junk email", "nevyžiadaná pošta"]),
            (.trash, ["trash", "deleted", "deleted items", "deleted messages", "kôš", "kos", "koš"]),
            (.archive, ["archive", "archív", "archiv"]),
        ]
        for (role, list) in names where list.contains(n) { return role }
        return .other
    }

    /// Only one folder per role keeps it; the others become ordinary folders. A folder the server marks (SPECIAL-USE,
    /// `marked`) wins over one only named like it: on Gmail a label called "Koncepty" or "Odoslané" is not the real
    /// Drafts or Sent ([Gmail]/…), and a draft "deleted" from such a label stays in All Mail. Then the shorter path.
    static func dedupeRoles(_ folders: [Folder], marked: Set<String> = []) -> [Folder] {
        var seen = Set<FolderRole>()
        return folders.sorted {
            let (a, b) = (marked.contains($0.path), marked.contains($1.path))
            return a != b ? a : $0.path.count < $1.path.count
        }.map { f in
            var f = f
            if f.role != .other { if seen.contains(f.role) { f.role = .other } else { seen.insert(f.role) } }
            return f
        }
    }

    // MARK: Messages

    static let headerFields = "BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)]"

    /// Fetches headers and flags of the newest `window` messages of a folder.
    public func syncMessages(_ a: Account, folder: String, window: Int = 300) async throws {
        try await with(a) { c in
            let sel = try await c.select(folder)
            if sel.uidValidity != 0, sel.uidValidity != store.uidValidity(account: a.id, folder: folder) {
                try store.clearFolder(account: a.id, folder: folder)
                try store.setUIDValidity(account: a.id, folder: folder, sel.uidValidity)
            }
            guard sel.exists > 0 else {
                try store.clearFolder(account: a.id, folder: folder)
                try store.setCounts(account: a.id, folder: folder, unread: 0, total: 0)
                return
            }
            let lo = max(1, sel.exists - window + 1)
            let items = try await c.fetch("\(lo):*", "UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE \(Self.headerFields)")
            let rows = items.compactMap { Self.headerRow($0, me: a.email) }
            let windowStart = lo == 1 ? 0 : rows.map(\.uid).min()
            let hadCache = store.cachedCount(account: a.id, folder: folder) > 0
            let known = store.knownUIDs(account: a.id, folder: folder)
            try store.upsertHeaders(account: a.id, folder: folder, rows, windowStart: windowStart)
            if hadCache, store.folders(account: a.id).first(where: { $0.path == folder })?.role == .inbox {
                let fresh = rows.filter { !known.contains($0.uid) && !$0.seen }.map(\.uid)
                arrived += store.ids(account: a.id, folder: folder, uids: fresh)
            }
            try saveStructure(a, folder, items)
            try store.setCounts(account: a.id, folder: folder, unread: rows.filter { !$0.seen }.count, total: sel.exists)
            try store.fixThreads(account: a.id)
            try store.reopenTickets(account: a.id, me: a.email)
        }
    }

    /// Fetches headers of older messages (below the oldest cached UID), `batch` at a time. Returns how many were added;
    /// 0 means the folder is complete.
    @discardableResult
    public func backfill(_ a: Account, folder: String, batch: Int = 200) async throws -> Int {
        guard let minUID = store.minUID(account: a.id, folder: folder), minUID > 1 else { return 0 }
        return try await with(a) { c in
            if c.selected != folder { try await c.select(folder) }
            let uids = try await c.uidSearch("UID 1:\(minUID - 1)").sorted(by: >).prefix(batch)
            guard !uids.isEmpty else { return 0 }
            let set = uids.map(String.init).joined(separator: ",")
            let items = try await c.fetch(set, "UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE \(Self.headerFields)", uid: true)
            try store.upsertHeaders(account: a.id, folder: folder, items.compactMap { Self.headerRow($0, me: a.email) }, windowStart: nil)
            try saveStructure(a, folder, items)
            try store.fixThreads(account: a.id)
            return items.count
        }
    }

    /// Attachment names for cached messages that were synced before BODYSTRUCTURE was fetched.
    func scanStructures(_ a: Account, folder: String, batch: Int = 300) async throws -> Int {
        let uids = ((try? store.run("SELECT uid FROM messages WHERE account_id=? AND folder=? AND attachments IS NULL AND fetched=0 LIMIT ?",
                                    [a.id, folder, batch])) ?? []).map { UInt32($0.i("uid")) }
        guard !uids.isEmpty else { return 0 }
        try await with(a) { c in
            if c.selected != folder { try await c.select(folder) }
            let items = try await c.fetch(uids.map(String.init).joined(separator: ","), "UID BODYSTRUCTURE", uid: true)
            try saveStructure(a, folder, items)
            // Messages the server no longer returns: mark as scanned so the loop ends.
            let got = Set(items.compactMap { $0["UID"]?.text.flatMap { UInt32($0) } })
            for u in uids where !got.contains(u) {
                try store.run("UPDATE messages SET attachments='[]' WHERE account_id=? AND folder=? AND uid=?", [a.id, folder, u])
            }
        }
        return uids.count
    }

    /// Categories for messages synced before they existed: refetch the few headers that decide it.
    func classifyOld(_ a: Account, folder: String, batch: Int = 300) async throws -> Int {
        let uids = store.unclassified(account: a.id, folder: folder, limit: batch)
        guard !uids.isEmpty else { return 0 }
        try await with(a) { c in
            if c.selected != folder { try await c.select(folder) }
            let items = try await c.fetch(uids.map(String.init).joined(separator: ","), "UID BODYSTRUCTURE \(Self.headerFields)", uid: true)
            var got = Set<UInt32>()
            try store.transaction {
                for f in items {
                    guard let row = Self.headerRow(f, me: a.email) else { continue }
                    got.insert(row.uid)
                    try store.setCategory(account: a.id, folder: folder, uid: row.uid, row.category)
                }
                for u in uids where !got.contains(u) { try store.setCategory(account: a.id, folder: folder, uid: u, .people) }
            }
        }
        return uids.count
    }

    /// Pulls the whole history of the inbox, sent and archive folders, a batch at a time.
    public func backfillAll(progress: (@Sendable (String) -> Void)? = nil) async {
        for a in store.accounts() {
            for f in store.folders(account: a.id) where f.selectable && [.inbox, .sent, .archive].contains(f.role) {
                if store.cachedCount(account: a.id, folder: f.path) == 0, f.total > 0 { try? await syncMessages(a, folder: f.path) }
                while let n = try? await classifyOld(a, folder: f.path), n > 0 {
                    progress?("\(a.email): triedim \(f.displayName)")
                }
                while let n = try? await scanStructures(a, folder: f.path), n > 0 {
                    progress?("\(a.email): prílohy v \(f.displayName)")
                }
                while let n = try? await backfill(a, folder: f.path), n > 0 {
                    progress?("\(a.email): \(f.displayName) \(store.cachedCount(account: a.id, folder: f.path))/\(f.total)")
                }
            }
        }
        progress?("")
    }

    func saveStructure(_ a: Account, _ folder: String, _ items: [[String: IMAPValue]]) throws {
        try store.transaction {
            for f in items {
                guard let uid = f["UID"]?.text.flatMap({ UInt32($0) }), let bs = f["BODYSTRUCTURE"] else { continue }
                try store.setAttachmentsMeta(account: a.id, folder: folder, uid: uid, BodyStructure.attachments(bs))
            }
        }
    }

    static func headerRow(_ f: [String: IMAPValue], me: String = "") -> Store.HeaderRow? {
        guard let uidText = f["UID"]?.text, let uid = UInt32(uidText) else { return nil }
        let flags = Set((f["FLAGS"]?.list ?? []).compactMap { $0.text?.lowercased() })
        let headers = MIME.parseHeaders(f["BODY[HEADER]"]?.data ?? Data())
        func h(_ n: String) -> String { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value ?? "" }
        let internalDate = f["INTERNALDATE"]?.text.flatMap(MIME.parseDate)
        let ct = h("Content-Type").lowercased()
        return Store.HeaderRow(
            uid: uid, messageID: Store.messageIDs(h("Message-ID")).first ?? "", subject: MIME.decodeWords(h("Subject")),
            from: MIME.parseAddresses(h("From")).first,
            to: MIME.parseAddresses(h("To")).map(\.full).joined(separator: ", "),
            cc: MIME.parseAddresses(h("Cc")).map(\.full).joined(separator: ", "),
            date: MIME.parseDate(h("Date")) ?? internalDate ?? Date(),
            seen: flags.contains("\\seen"), flagged: flags.contains("\\flagged"), answered: flags.contains("\\answered"),
            size: Int(f["RFC822.SIZE"]?.text ?? "") ?? 0,
            hasAttachments: ct.hasPrefix("multipart/mixed") || ct.hasPrefix("application/"),
            inReplyTo: Store.messageIDs(h("In-Reply-To")).last ?? "", references: Store.messageIDs(h("References")),
            unsubscribe: Unsubscribe.encode(header: h("List-Unsubscribe"), post: h("List-Unsubscribe-Post")),
            category: MailCategory.classify(
                from: h("From"), subject: MIME.decodeWords(h("Subject")),
                headers: ["list-unsubscribe": h("List-Unsubscribe"), "list-id": h("List-Id"), "precedence": h("Precedence"), "auto-submitted": h("Auto-Submitted")],
                attachmentNames: f["BODYSTRUCTURE"].map { BodyStructure.attachments($0).map(\.filename) } ?? [],
                hasCalendar: f["BODYSTRUCTURE"].map(BodyStructure.hasCalendar) ?? false,
                isMine: !me.isEmpty && (MIME.parseAddresses(h("From")).first?.address.lowercased() == me.lowercased())))
    }

    /// Downloads and parses a full message into the cache.
    @discardableResult
    public func fetchBody(_ m: MessageSummary) async throws -> MessageBody {
        if let b = store.body(id: m.id) { return b }
        guard let a = store.accounts().first(where: { $0.id == m.accountID }) else { throw MailError.notFound("účet neexistuje") }
        let raw: Data = try await with(a) { c in
            if c.selected != m.folder { try await c.select(m.folder) }
            let items = try await c.fetch("\(m.uid)", "UID BODY.PEEK[]", uid: true)
            guard let d = items.first(where: { $0["UID"]?.text == String(m.uid) })?["BODY[]"]?.data ?? items.first?["BODY[]"]?.data else {
                throw MailError.notFound("správa už na serveri nie je")
            }
            return d
        }
        try? raw.write(to: Store.rawURL(m.id))
        try store.saveBody(id: m.id, MIME.parseMessage(raw))
        return store.body(id: m.id)!
    }

    /// Bytes of one attachment (downloads the message first if needed).
    public func attachmentData(_ m: MessageSummary, index: Int, filename: String? = nil) async throws -> (Attachment, Data) {
        if !FileManager.default.fileExists(atPath: Store.rawURL(m.id).path) {
            try? store.run("UPDATE messages SET fetched=0 WHERE id=?", [m.id])
            _ = try await fetchBody(m)
        }
        let parsed = MIME.parseMessage(try Data(contentsOf: Store.rawURL(m.id)))
        // Indexes from BODYSTRUCTURE can differ from the parsed message; the file name decides when given.
        let i = filename.flatMap { n in parsed.attachments.firstIndex { $0.filename == n } } ?? index
        guard i >= 0, i < parsed.attachments.count else { throw MailError.notFound("príloha neexistuje") }
        return (parsed.attachments[i], parsed.attachmentData[i])
    }

    /// Saves an attachment into a folder (unique name), returns the file.
    public func saveAttachment(_ m: MessageSummary, index: Int, filename: String? = nil, to dir: URL) async throws -> URL {
        let (a, data) = try await attachmentData(m, index: index, filename: filename)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = a.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = dir.appendingPathComponent(safe)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        try data.write(to: url)
        return url
    }

    /// Downloads bodies of the newest small messages so lists show a preview and the MCP server can read them offline.
    public func prefetchBodies(_ a: Account, folder: String, limit: Int = 40) async {
        for m in store.unfetched(account: a.id, folder: folder, limit: limit, maxSize: 400_000) {
            _ = try? await fetchBody(m)
        }
    }

    public func setSeen(_ m: MessageSummary, _ seen: Bool) async throws {
        guard let a = store.accounts().first(where: { $0.id == m.accountID }) else { return }
        try store.setSeen(id: m.id, seen)
        try await with(a) { c in
            try await c.select(m.folder, readOnly: false)
            try await c.store(uid: m.uid, flags: "\\Seen", add: seen)
            try await c.select(m.folder)   // back to read-only so later fetches never change flags
        }
    }

    /// Folders, then the inbox (and other role folders) of every account.
    public func syncAll() async -> [String: String] {
        var errors: [String: String] = [:]
        for a in store.accounts() {
            do {
                try await syncFolders(a)
                for f in store.folders(account: a.id) where f.selectable && [.inbox, .sent, .drafts].contains(f.role) {
                    try await syncMessages(a, folder: f.path)
                }
                if let inbox = store.folders(account: a.id).first(where: { $0.role == .inbox }) {
                    await prefetchBodies(a, folder: inbox.path)
                }
            } catch { errors[a.id] = error.localizedDescription }
        }
        return errors
    }
}
