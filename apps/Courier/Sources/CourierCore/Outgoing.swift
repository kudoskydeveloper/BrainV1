import Foundation

/// A message to send or keep as a draft.
public struct OutgoingMessage: Codable, Sendable {
    public var accountID: String
    public var to: [EmailAddress]
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var subject: String
    public var body: String                     // plain text (with signature and quote already in)
    public var html: String? = nil              // optional HTML version (used when the signature is HTML)
    public var inReplyTo: String?               // message id without <>
    public var references: [String] = []
    public var attachments: [URL] = []
    public var messageID: String = "\(UUID().uuidString.lowercased())@courier.local"
    /// What the composer had before signature and quote were added, so a queued message can be edited again.
    public var composerText: String? = nil
    public var quoted: String? = nil
    public var signatureID: String? = nil
    public init(accountID: String, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String, body: String,
                inReplyTo: String? = nil, references: [String] = [], attachments: [URL] = []) {
        self.accountID = accountID; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.body = body
        self.inReplyTo = inReplyTo; self.references = references; self.attachments = attachments
    }
    public var recipients: [EmailAddress] { to + cc + bcc }
}

public enum MessageBuilder {
    static func encodeWord(_ s: String) -> String {
        s.allSatisfy { $0.isASCII && $0 != "\n" } ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func address(_ a: EmailAddress) -> String {
        guard !a.name.isEmpty else { return a.address }
        let n = a.name.allSatisfy(\.isASCII) ? "\"\(a.name.replacingOccurrences(of: "\"", with: ""))\"" : encodeWord(a.name)
        return "\(n) <\(a.address)>"
    }

    static func wrap76(_ b64: String) -> String {
        var out = "", line = ""
        for c in b64 { line.append(c); if line.count == 76 { out += line + "\r\n"; line = "" } }
        return out + (line.isEmpty ? "" : line + "\r\n")
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"; case "png": "image/png"; case "jpg", "jpeg": "image/jpeg"; case "gif": "image/gif"
        case "txt": "text/plain"; case "csv": "text/csv"; case "zip": "application/zip"; case "html": "text/html"
        case "doc": "application/msword"; case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": "application/vnd.ms-excel"; case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": "application/vnd.ms-powerpoint"; case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: "application/octet-stream"
        }
    }

    /// RFC 5322 message, ASCII only (text and attachments base64). Bcc is never written into the headers.
    public static func build(_ m: OutgoingMessage, from: EmailAddress, date: Date = Date()) throws -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var h = [
            "From: \(address(from))",
            "Date: \(df.string(from: date))",
            "Message-ID: <\(m.messageID)>",
            "Subject: \(encodeWord(m.subject))",
            "MIME-Version: 1.0",
            "User-Agent: Courier",
        ]
        if !m.to.isEmpty { h.insert("To: \(m.to.map(address).joined(separator: ", "))", at: 1) }
        if !m.cc.isEmpty { h.append("Cc: \(m.cc.map(address).joined(separator: ", "))") }
        if let r = m.inReplyTo, !r.isEmpty { h.append("In-Reply-To: <\(r)>") }
        if !m.references.isEmpty { h.append("References: \(m.references.map { "<\($0)>" }.joined(separator: " "))") }
        let text = m.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        var textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + wrap76(Data(text.utf8).base64EncodedString())
        if let html = m.html {
            let alt = "courier-alt-\(UUID().uuidString)"
            textPart = "Content-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n--\(alt)\r\n" + textPart
                + "--\(alt)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + wrap76(Data(html.utf8).base64EncodedString()) + "--\(alt)--\r\n"
        }
        if m.attachments.isEmpty {
            return h.joined(separator: "\r\n") + "\r\n" + textPart
        }
        let boundary = "courier-\(UUID().uuidString)"
        h.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var out = h.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\n" + textPart
        for url in m.attachments {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            out += "--\(boundary)\r\nContent-Type: \(mimeType(url)); name=\"\(encodeWord(name))\"\r\n"
            out += "Content-Disposition: attachment; filename=\"\(encodeWord(name))\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            out += wrap76(data.base64EncodedString())
        }
        return out + "--\(boundary)--\r\n"
    }
}

/// Minimal SMTP submission client: EHLO, STARTTLS, AUTH PLAIN/LOGIN/XOAUTH2, MAIL/RCPT/DATA.
public final class SMTPClient: @unchecked Sendable {
    let stream: MailStream
    var extensions: Set<String> = []

    public init(_ cfg: ServerConfig) async throws {
        stream = MailStream(host: cfg.host, port: cfg.port, ssl: cfg.security == .ssl, timeout: 60)
        _ = try await expect(220)
        try await ehlo()
        if cfg.security == .starttls {
            try await command("STARTTLS", 220)
            stream.startTLS()
            try await ehlo()
        }
    }

    deinit { stream.close() }

    func ehlo() async throws {
        let lines = try await command("EHLO courier.local", 250)
        extensions = Set(lines.map { String($0.dropFirst(4)).uppercased() })
    }

    @discardableResult
    func expect(_ code: Int) async throws -> [String] {
        var lines: [String] = []
        while true {
            let l = String(decoding: try await stream.readLine(), as: UTF8.self).trimmingCharacters(in: .newlines)
            lines.append(l)
            if l.count < 4 || l[l.index(l.startIndex, offsetBy: 3)] != "-" { break }
        }
        guard let last = lines.last, Int(last.prefix(3)) == code else {
            throw MailError.server("SMTP: \(lines.last ?? "?")")
        }
        return lines
    }

    @discardableResult
    func command(_ c: String, _ code: Int) async throws -> [String] {
        try await stream.write(c + "\r\n")
        return try await expect(code)
    }

    public func login(user: String, secret: String, oauth: Bool) async throws {
        let auth = extensions.first { $0.hasPrefix("AUTH") } ?? ""
        do {
            if oauth {
                let t = Data("user=\(user)\u{1}auth=Bearer \(secret)\u{1}\u{1}".utf8).base64EncodedString()
                try await command("AUTH XOAUTH2 \(t)", 235)
            } else if auth.contains("PLAIN") || auth.isEmpty {
                try await command("AUTH PLAIN \(Data("\0\(user)\0\(secret)".utf8).base64EncodedString())", 235)
            } else {
                try await command("AUTH LOGIN", 334)
                try await command(Data(user.utf8).base64EncodedString(), 334)
                try await command(Data(secret.utf8).base64EncodedString(), 235)
            }
        } catch MailError.server(let m) { throw MailError.auth(m) }
    }

    public func send(from: String, to: [String], data: String) async throws {
        try await command("MAIL FROM:<\(from)>", 250)
        for r in to { try await command("RCPT TO:<\(r)>", 250) }
        try await command("DATA", 354)
        // Dot-stuffing: a line starting with "." gets another one.
        let body = data.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        try await stream.write((body.hasPrefix(".") ? "." : "") + body + (body.hasSuffix("\r\n") ? "" : "\r\n") + ".\r\n")
        _ = try await expect(250)
    }

    public func quit() async { _ = try? await command("QUIT", 221); stream.close() }
}

extension IMAPClient {
    /// APPEND a whole message to a folder (as a literal).
    public func append(_ folder: String, message: String, flags: String) async throws {
        let n = message.utf8.count
        try await run("APPEND \(Self.quote(folder)) (\(flags)) {\(n)}", continuation: message)
    }

    /// Deletes messages in a folder by their Message-ID header (used to replace an older copy of a draft).
    public func deleteByMessageID(_ folder: String, _ id: String) async throws {
        try await select(folder, readOnly: false)
        let uids = try await uidSearch("HEADER Message-ID \(Self.quote("<\(id)>"))")
        if !uids.isEmpty {
            try await run("UID STORE \(uids.map(String.init).joined(separator: ",")) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(uids.map(String.init).joined(separator: ","))") } else { try await run("EXPUNGE") }
        }
        try await select(folder)
    }
}

extension MailSync {
    /// Sends over SMTP, then files a copy in Sent (Gmail does that by itself) and removes the draft copy, if any.
    public func send(_ m: OutgoingMessage) async throws {
        guard let a = store.accounts().first(where: { $0.id == m.accountID }) else { throw MailError.notFound("účet neexistuje") }
        guard let smtp = a.smtp else { throw MailError.notFound("účet nemá nastavený SMTP server") }
        guard let secret = Keychain.get(a.id) else { throw MailError.auth("v Keychaine chýba heslo") }
        guard !m.recipients.isEmpty else { throw MailError.notFound("chýba príjemca") }
        let raw = try MessageBuilder.build(m, from: EmailAddress(name: a.name == a.email ? "" : a.name, address: a.email))
        let c = try await SMTPClient(smtp)
        try await c.login(user: smtp.username, secret: secret, oauth: smtp.auth == .oauth2)
        try await c.send(from: a.email, to: m.recipients.map(\.address), data: raw)
        await c.quit()
        let folders = store.folders(account: a.id)
        let gmail = a.imap.host.hasSuffix("gmail.com")
        let drafts = folders.first(where: { $0.role == .drafts })
        try? await with(a) { c in
            // Each step on its own: a Sent copy that fails to save must not leave the draft behind.
            if !gmail, let sent = folders.first(where: { $0.role == .sent }) {
                try? await c.append(sent.path, message: raw, flags: "\\Seen")
            }
            if let drafts { try? await c.deleteByMessageID(drafts.path, m.messageID) }
            if let r = m.inReplyTo, let orig = store.message(messageID: r, account: a.id) {
                try? await c.select(orig.folder, readOnly: false)
                try? await c.store(uid: orig.uid, flags: "\\Answered", add: true)
                try? await c.select(orig.folder)
            }
        }
        // The draft is gone from the server; the cached copy goes too, and Drafts is read again.
        if let drafts {
            try? store.deleteMessages(account: a.id, folder: drafts.path, messageID: m.messageID)
            try? await syncMessages(a, folder: drafts.path)
        }
        if let sent = folders.first(where: { $0.role == .sent }) { try? await syncMessages(a, folder: sent.path) }
    }

    /// Saves (or replaces) the draft in the server's Drafts folder.
    public func saveDraft(_ m: OutgoingMessage) async throws {
        guard let a = store.accounts().first(where: { $0.id == m.accountID }) else { throw MailError.notFound("účet neexistuje") }
        guard let drafts = store.folders(account: a.id).first(where: { $0.role == .drafts }) else { throw MailError.notFound("účet nemá priečinok Koncepty") }
        let raw = try MessageBuilder.build(m, from: EmailAddress(name: a.name == a.email ? "" : a.name, address: a.email))
        try await with(a) { c in
            try? await c.deleteByMessageID(drafts.path, m.messageID)
            try await c.append(drafts.path, message: raw, flags: "\\Seen \\Draft")
        }
        try? await syncMessages(a, folder: drafts.path)
    }
}

// MARK: Outbox

/// A message waiting to go out: either the undo window of a normal send (a few seconds) or a scheduled send.
public struct OutboxItem: Codable, Identifiable, Sendable {
    public var id: String
    public var message: OutgoingMessage
    public var sendAt: Date
    public var error: String?
    public var scheduled: Bool { sendAt.timeIntervalSinceNow > 30 || error != nil }
}

public struct Signature: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var body: String
    public var isHTML: Bool
    public init(id: String = UUID().uuidString, name: String, body: String, isHTML: Bool = false) {
        self.id = id; self.name = name; self.body = body; self.isHTML = isHTML
    }
    /// Plain-text form for the text/plain part.
    public var plain: String { isHTML ? MIME.stripHTML(body).replacingOccurrences(of: "\n\\s*\n+", with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) : body }
}

extension Store {
    static var outboxFiles: URL {
        let d = directory.appendingPathComponent("Outbox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func migrateOutbox() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY, message TEXT, send_at REAL, error TEXT);
        CREATE TABLE IF NOT EXISTS signatures(id TEXT PRIMARY KEY, name TEXT, body TEXT, is_html INT, sort INT DEFAULT 0);
        CREATE TABLE IF NOT EXISTS signature_defaults(account_id TEXT PRIMARY KEY, signature_id TEXT);
        """)
    }

    /// Queues a message; attachments are copied next to the database so a later (scheduled) send still finds them.
    @discardableResult
    public func enqueue(_ m: OutgoingMessage, at: Date) throws -> OutboxItem {
        let id = UUID().uuidString
        var m = m
        let dir = Self.outboxFiles.appendingPathComponent(id)
        if !m.attachments.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            m.attachments = try m.attachments.map { u in
                let dst = dir.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: u, to: dst)
                return dst
            }
        }
        let item = OutboxItem(id: id, message: m, sendAt: at)
        try run("INSERT INTO outbox(id,message,send_at,error) VALUES(?,?,?,NULL)", [id, Self.json(m), at])
        return item
    }

    public func outbox() -> [OutboxItem] {
        ((try? run("SELECT * FROM outbox ORDER BY send_at")) ?? []).compactMap { r in
            guard let m: OutgoingMessage = r.json("message") else { return nil }
            return OutboxItem(id: r.s("id"), message: m, sendAt: Date(timeIntervalSince1970: r.d("send_at")), error: r.os("error"))
        }
    }

    /// Removes a queued message; returns it if it was still there (so undo can reopen it).
    @discardableResult
    public func dequeue(_ id: String, keepFiles: Bool = false) -> OutboxItem? {
        let item = outbox().first { $0.id == id }
        try? run("DELETE FROM outbox WHERE id=?", [id])
        if !keepFiles { try? FileManager.default.removeItem(at: Self.outboxFiles.appendingPathComponent(id)) }
        return item
    }

    public func markFailed(_ id: String, _ error: String) { try? run("UPDATE outbox SET error=? WHERE id=?", [error, id]) }
    public func reschedule(_ id: String, at: Date) { try? run("UPDATE outbox SET send_at=?, error=NULL WHERE id=?", [at, id]) }

    // MARK: Signatures

    public func signatures() -> [Signature] {
        ((try? run("SELECT * FROM signatures ORDER BY sort, name")) ?? []).map {
            Signature(id: $0.s("id"), name: $0.s("name"), body: $0.s("body"), isHTML: $0.i("is_html") != 0)
        }
    }
    public func save(_ s: Signature) throws {
        try run("INSERT OR REPLACE INTO signatures(id,name,body,is_html) VALUES(?,?,?,?)", [s.id, s.name, s.body, s.isHTML])
    }
    public func deleteSignature(_ id: String) throws {
        try run("DELETE FROM signatures WHERE id=?", [id])
        try run("DELETE FROM signature_defaults WHERE signature_id=?", [id])
    }
    public func defaultSignature(account: String) -> String? {
        (try? run("SELECT signature_id FROM signature_defaults WHERE account_id=?", [account]))?.first?.os("signature_id")
    }
    public func setDefaultSignature(account: String, _ id: String?) throws {
        if let id { try run("INSERT OR REPLACE INTO signature_defaults(account_id,signature_id) VALUES(?,?)", [account, id]) }
        else { try run("DELETE FROM signature_defaults WHERE account_id=?", [account]) }
    }
}

extension MailSync {
    /// Sends every queued message whose time has come. Failures stay in the outbox with their error.
    ///
    /// The actor lets another flush in while this one waits on SMTP (the outbox timer ticks every second), so each item is
    /// claimed before the first await: a message can't go out twice.
    public func flushOutbox() async -> [String] {
        var sent: [String] = []
        for item in store.outbox() where item.sendAt <= Date() && item.error == nil && !sending.contains(item.id) {
            guard store.outbox().contains(where: { $0.id == item.id }) else { continue }   // undone meanwhile
            sending.insert(item.id)
            defer { sending.remove(item.id) }
            do {
                try await send(item.message)
                store.dequeue(item.id)
                sent.append(item.id)
            } catch {
                store.markFailed(item.id, error.localizedDescription)
            }
        }
        return sent
    }
}

extension OutgoingMessage {
    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Final text: what the user wrote, the signature, then the quoted original. An HTML signature adds an HTML part.
    public mutating func compose(text: String, signature: Signature?, quoted: String) {
        var plain = text.trimmingCharacters(in: .newlines)
        if let s = signature, !s.plain.isEmpty { plain += "\n\n" + s.plain }
        if !quoted.isEmpty { plain += "\n\n" + quoted }
        body = plain
        if let s = signature, s.isHTML {
            var h = "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">" + Self.escapeHTML(text.trimmingCharacters(in: .newlines)) + "</div>"
            h += "<br><div class=\"courier-signature\">" + s.body + "</div>"
            if !quoted.isEmpty {
                let lines = quoted.split(separator: "\n", omittingEmptySubsequences: false)
                let header = lines.first.map(String.init) ?? ""
                let rest = lines.dropFirst().map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : ($0 == ">" ? "" : String($0)) }.joined(separator: "\n")
                h += "<br><div>" + Self.escapeHTML(header) + "</div><blockquote type=\"cite\" style=\"margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex\">"
                    + Self.escapeHTML(rest) + "</blockquote>"
            }
            html = "<!doctype html><html><body>" + h + "</body></html>"
        } else {
            html = nil
        }
    }
}

// MARK: Delete, archive, move

extension IMAPClient {
    /// Moves messages (selected folder, read-write) to another folder: MOVE when the server has it, else COPY + delete.
    func moveUIDs(_ uids: [UInt32], to target: String) async throws {
        let set = uids.map(String.init).joined(separator: ",")
        if capabilities.contains("MOVE") {
            try await run("UID MOVE \(set) \(Self.quote(target))")
        } else {
            try await run("UID COPY \(set) \(Self.quote(target))")
            try await expungeUIDs(uids)
        }
    }

    /// Permanently removes messages from the selected folder.
    func expungeUIDs(_ uids: [UInt32]) async throws {
        let set = uids.map(String.init).joined(separator: ",")
        try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(set)") } else { try await run("EXPUNGE") }
    }
}

extension MailSync {
    /// Moves messages to `target` (a folder path), or deletes them for good when `target` is nil.
    /// Works per account and folder; the local cache drops them right away, the target folder is resynced.
    public func move(_ messages: [MessageSummary], to target: String?) async throws {
        let groups = Dictionary(grouping: messages) { "\($0.accountID)\u{1}\($0.folder)" }
        var touched: [(Account, String)] = []
        for (_, list) in groups {
            guard let first = list.first, let a = store.accounts().first(where: { $0.id == first.accountID }) else { continue }
            let uids = list.map(\.uid)
            try await with(a) { c in
                try await c.select(first.folder, readOnly: false)
                if let target, target != first.folder { try await c.moveUIDs(uids, to: target) } else if target == nil { try await c.expungeUIDs(uids) }
                try await c.select(first.folder)
            }
            try store.transaction {
                for m in list { try store.run("DELETE FROM messages WHERE id=?", [m.id]); try? FileManager.default.removeItem(at: Store.rawURL(m.id)) }
            }
            if let target { touched.append((a, target)) }
            if let f = store.folders(account: a.id).first(where: { $0.path == first.folder }) {
                try? store.setCounts(account: a.id, folder: f.path, unread: max(0, f.unread - list.filter { !$0.seen }.count), total: max(0, f.total - list.count))
            }
        }
        for (a, t) in touched { try? await syncMessages(a, folder: t) }
    }
}
