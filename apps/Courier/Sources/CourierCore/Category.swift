import Foundation

/// What kind of mail a message is. Everything that is not from a person is kept out of the way (bundled) in lists.
public enum MailCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case people, notifications, newsletters, invites, invoices
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .people: "Ľudia"; case .notifications: "Notifikácie"; case .newsletters: "Newslettre"
        case .invites: "Pozvánky"; case .invoices: "Faktúry a platby"
        }
    }
    public var symbol: String {
        switch self {
        case .people: "person.2.fill"; case .notifications: "bell.fill"; case .newsletters: "newspaper.fill"
        case .invites: "calendar"; case .invoices: "doc.text.fill"
        }
    }
    public var colorName: String {
        switch self { case .people: "blue"; case .notifications: "orange"; case .newsletters: "purple"; case .invites: "red"; case .invoices: "green" }
    }

    static let inviteSubject = try! NSRegularExpression(pattern:
        #"^\s*(invitation|updated invitation|pozvánka|aktualizovaná pozvánka|accepted|prijaté|prijatá|declined|odmietnuté|odmietnutá|tentative|tentatively accepted|predbežne prijaté|canceled|cancelled|zrušené|new event|nová udalosť)\b"#,
        options: [.caseInsensitive])
    static let invoiceWords = ["faktúra", "faktura", "invoice", "receipt", "účtenka", "uctenka", "potvrdenie platby", "payment received",
                               "payment confirmation", "platba prijatá", "objednávka", "order confirmation", "vyúčtovanie", "dobropis", "proforma",
                               "zálohová", "billing", "your bill"]
    static let robotSenders = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications@", "notification@", "notify@",
                               "alerts@", "alert@", "mailer-daemon", "postmaster@", "automated@", "system@", "bounce", "updates@", "info@",
                               "news@", "newsletter", "hello@mail.", "support@", "team@", "calendar-notification", "@calendar.", "jira@", "github.com",
                               "notion.so", "slack.com", "linear.app", "atlassian.net"]

    /// Header-based classification. Order matters: an invite or an invoice stays one even when sent in bulk.
    public static func classify(from: String, subject: String, headers: [String: String], attachmentNames: [String] = [],
                                hasCalendar: Bool = false, isMine: Bool = false) -> MailCategory {
        if isMine { return .people }
        let s = subject.lowercased()
        let f = from.lowercased()
        if hasCalendar || inviteSubject.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil { return .invites }
        let names = attachmentNames.map { $0.lowercased() }
        if invoiceWords.contains(where: { s.contains($0) }) || names.contains(where: { $0.contains("faktur") || $0.contains("invoice") || $0.contains("receipt") }) {
            return .invoices
        }
        let h = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.lowercased()) })
        let precedence = h["precedence"] ?? ""
        let auto = h["auto-submitted"] ?? ""
        let unsubscribe = !(h["list-unsubscribe"] ?? "").isEmpty
        if unsubscribe {
            // A List-Unsubscribe header means a mailing; ones from systems (no-reply, notifications@) are notifications.
            if robotSenders.prefix(9).contains(where: { f.contains($0) }) || f.contains("github.com") || f.contains("atlassian.net") || f.contains("slack.com") {
                return .notifications
            }
            return .newsletters
        }
        if (!auto.isEmpty && auto != "no") || precedence.contains("bulk") || precedence.contains("auto_reply") || precedence.contains("junk") {
            return .notifications
        }
        if robotSenders.contains(where: { f.contains($0) }) { return .notifications }
        return .people
    }
}

extension MailSync {
    /// Marks many messages read/unread with one STORE per folder.
    public func setSeen(_ messages: [MessageSummary], _ seen: Bool) async throws {
        for (_, list) in Dictionary(grouping: messages, by: { "\($0.accountID)\u{1}\($0.folder)" }) {
            guard let first = list.first, let a = store.accounts().first(where: { $0.id == first.accountID }) else { continue }
            for m in list { try store.setSeen(id: m.id, seen) }
            try await with(a) { c in
                try await c.select(first.folder, readOnly: false)
                try await c.run("UID STORE \(list.map { String($0.uid) }.joined(separator: ",")) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")
                try await c.select(first.folder)
            }
            if let f = store.folders(account: a.id).first(where: { $0.path == first.folder }) {
                let delta = list.filter { $0.seen != seen }.count
                try? store.setCounts(account: a.id, folder: f.path, unread: max(0, f.unread + (seen ? -delta : delta)), total: f.total)
            }
        }
    }
}
