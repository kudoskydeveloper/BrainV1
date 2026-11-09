import Foundation

/// How to get off a mailing list, from the message's List-Unsubscribe (RFC 2369) and List-Unsubscribe-Post (RFC 8058) headers.
public struct UnsubscribeMethod: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case oneClick   // HTTPS POST, no page to visit (RFC 8058): Courier does it by itself
        case mail       // an e-mail to the list's unsubscribe address, sent from the user's account
        case web        // only a web page: the user finishes it in the browser
    }
    public var kind: Kind
    public var url: URL
    public var sender: String

    /// One line for previews, in Slovak like the rest of the UI.
    public var summary: String {
        switch kind {
        case .oneClick: "odhlásenie jedným klikom cez \(url.host ?? url.absoluteString)"
        case .mail: "odhlasovací e-mail na \(Unsubscribe.mailto(url).to)"
        case .web: "len cez webovú stránku \(url.host ?? url.absoluteString), treba ju otvoriť v prehliadači"
        }
    }
    public var automatic: Bool { kind != .web }
}

public enum Unsubscribe {
    /// What is kept in the cache: the header and, on a second line, List-Unsubscribe-Post. Empty when the message has none.
    public static func encode(header: String, post: String) -> String {
        let h = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? "" : h + "\n" + post.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The best way out: one-click POST, else e-mail, else a web page.
    public static func method(stored: String, sender: String) -> UnsubscribeMethod? {
        let lines = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, !header.isEmpty else { return nil }
        let oneClick = (lines.count > 1 ? lines[1] : "").lowercased().contains("one-click")
        let urls = targets(header)
        let https = urls.first { $0.scheme?.lowercased() == "https" }
        let web = https ?? urls.first { $0.scheme?.lowercased() == "http" }
        let mail = urls.first { $0.scheme?.lowercased() == "mailto" && !mailto($0).to.isEmpty }
        if oneClick, let https { return UnsubscribeMethod(kind: .oneClick, url: https, sender: sender) }
        if let mail { return UnsubscribeMethod(kind: .mail, url: mail, sender: sender) }
        if let web { return UnsubscribeMethod(kind: .web, url: web, sender: sender) }
        return nil
    }

    /// `<mailto:a@b?subject=x>, <https://…>` → URLs in header order.
    static func targets(_ header: String) -> [URL] {
        var out: [URL] = []
        var cur: String?
        for ch in header {
            if ch == "<" { cur = "" } else if ch == ">" {
                if let c = cur, let u = URL(string: c.filter { !$0.isWhitespace }) { out.append(u) }
                cur = nil
            } else { cur?.append(ch) }
        }
        return out
    }

    /// mailto:list@x?subject=unsubscribe&body=… → address, subject, body.
    public static func mailto(_ url: URL) -> (to: String, subject: String, body: String) {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = (c?.path ?? "").removingPercentEncoding ?? c?.path ?? ""
        func q(_ n: String) -> String? { c?.queryItems?.first { $0.name.lowercased() == n }?.value }
        return (to.split(separator: ",").first.map(String.init) ?? "", q("subject") ?? "unsubscribe", q("body") ?? "unsubscribe")
    }

    /// Reads List-Unsubscribe out of a raw message (cached .eml).
    static func fromRaw(_ data: Data) -> String {
        let end = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? data.range(of: Data("\n\n".utf8))?.lowerBound ?? data.endIndex
        let headers = MIME.parseHeaders(data[data.startIndex..<end])
        func h(_ n: String) -> String { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value ?? "" }
        return encode(header: h("List-Unsubscribe"), post: h("List-Unsubscribe-Post"))
    }
}

extension MailSync {
    /// How to unsubscribe from the list that sent `m`; nil when the message carries no List-Unsubscribe.
    /// Messages cached before Courier kept the header get it from the cached .eml, else one small IMAP fetch.
    public func unsubscribeMethod(_ m: MessageSummary) async throws -> UnsubscribeMethod? {
        var stored = store.unsubscribeHeader(id: m.id)
        if stored == nil, let raw = try? Data(contentsOf: Store.rawURL(m.id)) { stored = Unsubscribe.fromRaw(raw) }
        if stored == nil, let a = store.accounts().first(where: { $0.id == m.accountID }) {
            stored = try await with(a) { c in
                try await c.select(m.folder)
                let items = try await c.fetch("\(m.uid)", "UID BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)]", uid: true)
                let headers = MIME.parseHeaders(items.first?["BODY[HEADER]"]?.data ?? Data())
                func h(_ n: String) -> String { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value ?? "" }
                return Unsubscribe.encode(header: h("List-Unsubscribe"), post: h("List-Unsubscribe-Post"))
            }
        }
        if let stored { try? store.setUnsubscribeHeader(id: m.id, stored) }
        return Unsubscribe.method(stored: stored ?? "", sender: m.fromAddress)
    }

    /// Unsubscribes by one-click POST or by e-mail. A web-only list throws: the caller opens `method.url` for the user.
    public func unsubscribe(_ m: MessageSummary, using method: UnsubscribeMethod) async throws {
        switch method.kind {
        case .oneClick:
            var req = URLRequest(url: method.url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(code) else { throw MailError.server("odhlásenie odmietnuté (HTTP \(code))") }
        case .mail:
            let t = Unsubscribe.mailto(method.url)
            try await send(OutgoingMessage(accountID: m.accountID, to: [EmailAddress(name: "", address: t.to)], subject: t.subject, body: t.body))
        case .web:
            throw MailError.notFound("tento odosielateľ sa dá odhlásiť len na webe: \(method.url.absoluteString)")
        }
    }

    /// The whole clean-up: unsubscribe (web-only lists are left to the caller, who opens the page), file the sender under
    /// Newsletters so whatever still comes stays bundled, and optionally archive what the sender has in the inboxes.
    /// Returns how many messages were archived.
    @discardableResult
    public func unsubscribeAndClean(_ m: MessageSummary, using method: UnsubscribeMethod, archive: Bool) async throws -> Int {
        if method.automatic { try await unsubscribe(m, using: method) }
        try? store.setSenderCategory(m.fromAddress, .newsletters)
        store.reloadOverrides()
        guard archive else { return 0 }
        let inbox = store.messages(from: m.fromAddress)
        for (acc, msgs) in Dictionary(grouping: inbox, by: \.accountID) {
            let folders = store.folders(account: acc)
            guard let path = (folders.first { $0.role == .archive } ?? folders.first { $0.role == .all })?.path else { continue }
            try await move(msgs, to: path)
        }
        return inbox.count
    }
}
