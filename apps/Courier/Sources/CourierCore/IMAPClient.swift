import Foundation

public enum MailError: LocalizedError {
    case connection(String)
    case auth(String)
    case server(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let s): return "Spojenie zlyhalo: \(s)"
        case .auth(let s): return "Prihlásenie zlyhalo: \(s)"
        case .server(let s): return "Server odpovedal chybou: \(s)"
        case .notFound(let s): return s
        }
    }
}

public enum Security: String, Codable, Sendable { case ssl, starttls, plain }

/// A byte stream to a mail server over URLSessionStreamTask (TLS from the start or upgraded via STARTTLS).
final class MailStream: @unchecked Sendable {
    private let task: URLSessionStreamTask
    private var buffer = Data()
    let timeout: TimeInterval

    init(host: String, port: Int, ssl: Bool, timeout: TimeInterval = 30) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        task.resume()
        if ssl { task.startSecureConnection() }
    }

    func startTLS() { task.startSecureConnection() }

    // Foundation's async readData/write overloads can resume their continuation twice when the connection
    // drops (seen after wake from sleep), which crashes in swift_continuation_throwingResumeWithError.
    // These wrappers use the completion-handler APIs and resume at most once.
    func write(_ s: String) async throws {
        let task = self.task, timeout = self.timeout
        let error: Error? = await withCheckedContinuation { cont in
            let once = ResumeOnce()
            task.write(Data(s.utf8), timeout: timeout) { err in
                if once.claim() { cont.resume(returning: err) }
            }
        }
        if let error { throw MailError.connection(error.localizedDescription) }
    }

    private func fill() async throws {
        let task = self.task, timeout = self.timeout
        let (data, eof, error): (Data?, Bool, Error?) = await withCheckedContinuation { cont in
            let once = ResumeOnce()
            task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: timeout) { data, eof, err in
                if once.claim() { cont.resume(returning: (data, eof, err)) }
            }
        }
        if let error { throw MailError.connection(error.localizedDescription) }
        if let data, !data.isEmpty { buffer.append(data); return }
        if eof { throw MailError.connection("server zavrel spojenie") }
    }

    /// One line including its CRLF.
    func readLine() async throws -> Data {
        while true {
            if let r = buffer.firstRange(of: Data([0x0D, 0x0A])) {
                let line = buffer[buffer.startIndex..<r.upperBound]
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return Data(line)
            }
            try await fill()
        }
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let d = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(d)
    }

    func close() { task.closeWrite(); task.cancel() }
}

/// Lets only the first of possibly several completion callbacks through.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// One response from the server: raw bytes of the whole logical line (with literals) and its parsed values.
public struct IMAPResponse: Sendable {
    public let raw: Data
    public var line: String { String(decoding: raw.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    public var values: [IMAPValue] { IMAPParser.parse(raw) }
}

/// A minimal IMAP4rev1 client: enough for login, LIST/STATUS/SELECT, FETCH and STORE. Not thread-safe; use from one actor.
public final class IMAPClient: @unchecked Sendable {
    let stream: MailStream
    var tag = 0
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: String?

    public init(host: String, port: Int, security: Security) async throws {
        stream = MailStream(host: host, port: port, ssl: security == .ssl)
        let greeting = try await readResponse()
        guard greeting.line.hasPrefix("* OK") || greeting.line.hasPrefix("* PREAUTH") else {
            throw MailError.connection("neočakávaný pozdrav: \(greeting.line)")
        }
        if security == .starttls {
            try await run("STARTTLS")
            stream.startTLS()
        }
        try await refreshCapabilities()
    }

    deinit { stream.close() }

    func readResponse() async throws -> IMAPResponse {
        var raw = Data()
        while true {
            let line = try await stream.readLine()
            raw.append(line)
            // A line ending in {n}\r\n (or {n+}) is followed by n bytes of literal, then the rest of the response.
            let body = line.dropLast(2)
            guard body.last == 0x7D, let open = body.lastIndex(of: 0x7B) else { break }
            let digits = String(decoding: body[body.index(after: open)..<body.index(before: body.endIndex)], as: UTF8.self)
                .replacingOccurrences(of: "+", with: "")
            guard let n = Int(digits) else { break }
            raw.append(try await stream.read(count: n))
        }
        return IMAPResponse(raw: raw)
    }

    /// Sends a command and returns its untagged responses. Throws on NO/BAD. `continuation` answers a `+` request.
    @discardableResult
    public func run(_ command: String, continuation: String? = nil, redact: Bool = false) async throws -> [IMAPResponse] {
        tag += 1
        let t = "C\(tag)"
        try await stream.write("\(t) \(command)\r\n")
        var untagged: [IMAPResponse] = []
        var sentContinuation = false
        while true {
            let r = try await readResponse()
            let line = r.line
            if line.hasPrefix("+") {
                if let continuation, !sentContinuation { sentContinuation = true; try await stream.write(continuation + "\r\n") }
                else { try await stream.write("*\r\n") }   // cancel an unexpected request
                continue
            }
            if line.hasPrefix(t + " ") {
                let rest = line.dropFirst(t.count + 1)
                if rest.uppercased().hasPrefix("OK") { return untagged }
                let msg = String(rest.dropFirst(rest.uppercased().hasPrefix("NO") ? 2 : 3)).trimmingCharacters(in: .whitespaces)
                throw MailError.server(redact ? msg : "\(command.split(separator: " ").first ?? ""): \(msg)")
            }
            untagged.append(r)
        }
    }

    func refreshCapabilities() async throws {
        let rs = try await run("CAPABILITY")
        for r in rs where r.line.uppercased().hasPrefix("* CAPABILITY") {
            capabilities = Set(r.line.dropFirst(13).uppercased().split(separator: " ").map(String.init))
        }
    }

    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func login(user: String, password: String) async throws {
        do {
            if capabilities.contains("AUTH=PLAIN") {
                let token = Data("\0\(user)\0\(password)".utf8).base64EncodedString()
                try await run("AUTHENTICATE PLAIN", continuation: token, redact: true)
            } else {
                try await run("LOGIN \(Self.quote(user)) \(Self.quote(password))", redact: true)
            }
        } catch MailError.server(let m) { throw MailError.auth(m) }
        try await refreshCapabilities()
    }

    public func loginOAuth(user: String, accessToken: String) async throws {
        let token = Data("user=\(user)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}".utf8).base64EncodedString()
        do { try await run("AUTHENTICATE XOAUTH2", continuation: token, redact: true) } catch MailError.server(let m) { throw MailError.auth(m) }
        try await refreshCapabilities()
    }

    public struct ListedFolder: Sendable {
        public let path: String          // as the server names it (modified UTF-7)
        public let delimiter: String?
        public let attributes: Set<String>
    }

    public func list() async throws -> [ListedFolder] {
        let rs = try await run(capabilities.contains("SPECIAL-USE") ? "LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "LIST \"\" \"*\"")
        return rs.compactMap { r in
            let v = r.values
            guard v.count >= 5, v[1].text?.uppercased() == "LIST", let attrs = v[2].list, let name = v[4].text else { return nil }
            return ListedFolder(path: name, delimiter: v[3].text, attributes: Set(attrs.compactMap { $0.text?.lowercased() }))
        }
    }

    public struct Status: Sendable { public var messages = 0, unseen = 0, uidValidity: UInt32 = 0, uidNext: UInt32 = 0 }

    public func status(_ path: String) async throws -> Status {
        let rs = try await run("STATUS \(Self.quote(path)) (MESSAGES UNSEEN UIDVALIDITY UIDNEXT)")
        var s = Status()
        for r in rs {
            let v = r.values
            guard v.count >= 4, v[1].text?.uppercased() == "STATUS", let items = v.last?.list else { continue }
            Self.pairs(items) { k, val in
                let n = Int(val.text ?? "") ?? 0
                switch k { case "MESSAGES": s.messages = n; case "UNSEEN": s.unseen = n
                case "UIDVALIDITY": s.uidValidity = UInt32(n); case "UIDNEXT": s.uidNext = UInt32(n); default: break }
            }
        }
        return s
    }

    public struct Selected: Sendable { public var exists = 0, uidValidity: UInt32 = 0, uidNext: UInt32 = 0 }

    @discardableResult
    public func select(_ path: String, readOnly: Bool = true) async throws -> Selected {
        let rs = try await run("\(readOnly ? "EXAMINE" : "SELECT") \(Self.quote(path))")
        selected = path
        var s = Selected()
        for r in rs {
            let l = r.line
            let up = l.uppercased()
            if up.hasSuffix(" EXISTS") { s.exists = Int(l.split(separator: " ")[1]) ?? 0 }
            if let n = Self.code(up, "UIDVALIDITY") { s.uidValidity = UInt32(n) ?? 0 }
            if let n = Self.code(up, "UIDNEXT") { s.uidNext = UInt32(n) ?? 0 }
        }
        return s
    }

    static func code(_ line: String, _ name: String) -> String? {
        guard let r = line.range(of: "[\(name) ") else { return nil }
        return line[r.upperBound...].prefix { $0.isNumber }.description
    }

    /// FETCH responses as attribute dictionaries (keys uppercased, e.g. "UID", "FLAGS", "BODY[]").
    public func fetch(_ set: String, _ items: String, uid: Bool = false) async throws -> [[String: IMAPValue]] {
        let rs = try await run("\(uid ? "UID " : "")FETCH \(set) (\(items))")
        return rs.compactMap { r in
            let v = r.values
            guard v.count >= 4, v[2].text?.uppercased() == "FETCH", let items = v[3].list else { return nil }
            var d: [String: IMAPValue] = [:]
            Self.pairs(items) { k, val in d[Self.normalizeKey(k)] = val }
            return d
        }
    }

    /// `BODY[HEADER.FIELDS (FROM TO)]` → `BODY[HEADER]`, `BODY[]<0>` → `BODY[]`, to look attributes up simply.
    static func normalizeKey(_ k: String) -> String {
        var k = k.uppercased()
        if let lt = k.firstIndex(of: "<") { k = String(k[..<lt]) }
        if k.hasPrefix("BODY[HEADER.FIELDS") || k.hasPrefix("BODY.PEEK[HEADER.FIELDS") { return "BODY[HEADER]" }
        return k.replacingOccurrences(of: "BODY.PEEK[", with: "BODY[")
    }

    static func pairs(_ items: [IMAPValue], _ body: (String, IMAPValue) -> Void) {
        var i = 0
        while i + 1 < items.count {
            if let k = items[i].text { body(k.uppercased(), items[i + 1]) }
            i += 2
        }
    }

    public func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let rs = try await run("UID SEARCH \(criteria)")
        return rs.flatMap { r -> [UInt32] in
            let l = r.line
            guard l.uppercased().hasPrefix("* SEARCH") else { return [] }
            return l.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
        }
    }

    public func store(uid: UInt32, flags: String, add: Bool) async throws {
        try await run("UID STORE \(uid) \(add ? "+" : "-")FLAGS.SILENT (\(flags))")
    }

    public func logout() async { _ = try? await run("LOGOUT"); stream.close() }
}
