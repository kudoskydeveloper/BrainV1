#if os(iOS)
import Foundation
import Observation
import CourierCore

/// App state for the iPhone: the same SQLite cache, IMAP sync and Keychain as the Mac app, without the board and the MCP socket.
@MainActor @Observable
final class MobileModel {
    let store: Store
    let sync: MailSync

    var accounts: [Account] = []
    var projects: [Project] = []
    var inbox: [MessageSummary] = []
    var stats: [String: (count: Int, unread: Int)] = [:]
    var accountErrors: [String: String] = [:]
    var bodies: [Int64: MessageBody] = [:]
    var bodyErrors: [Int64: String] = [:]
    var refreshing = false
    var lastError: String?

    init() {
        Self.importMacSecrets()
        store = try! Store()
        sync = MailSync(store: store)
        reload()
    }

    /// One-time hand-off from the Mac (copied over USB by import-from-mac.sh): `mac-secrets.json` = {account id: password}.
    /// The passwords go into this iPhone's Keychain and the file is deleted right away, whether or not every save worked.
    private static func importMacSecrets() {
        let file = URL.applicationSupportDirectory.appendingPathComponent("Courier/mac-secrets.json")
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (account, secret) in secrets { try? Keychain.set(secret, for: account) }
    }

    func reload() {
        accounts = store.accounts()
        projects = store.projects()
        inbox = Self.conversations(store.unifiedInbox(limit: 600))
        stats = store.threadStats(Set(inbox.map(\.threadKey)))
    }

    /// Newest message of each conversation, newest first.
    static func conversations(_ list: [MessageSummary]) -> [MessageSummary] {
        var seen = Set<String>()
        return list.sorted { $0.date > $1.date }.filter { seen.insert($0.threadKey).inserted }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    func unread(_ m: MessageSummary) -> Bool { (stats[m.threadKey]?.unread ?? (m.seen ? 0 : 1)) > 0 }
    func count(_ m: MessageSummary) -> Int { stats[m.threadKey]?.count ?? 1 }

    func projectMessages(_ p: Project) -> [MessageSummary] { Self.conversations(store.messages(project: p, limit: 400)) }
    func unreadCount(_ p: Project) -> Int { store.unreadCount(project: p) }
    func search(_ q: String) -> [MessageSummary] { Self.conversations(store.search(q, limit: 150)) }
    func thread(_ m: MessageSummary) -> [MessageSummary] {
        let t = store.thread(account: m.accountID, id: m.threadID)
        return t.isEmpty ? [m] : t
    }

    // MARK: Sync

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        accountErrors = await sync.syncAll()
        refreshing = false
        reload()
    }

    func body(_ m: MessageSummary) async {
        if bodies[m.id] != nil { return }
        if let b = store.body(id: m.id) { bodies[m.id] = b; return }
        do { bodies[m.id] = try await sync.fetchBody(m); bodyErrors[m.id] = nil } catch { bodyErrors[m.id] = error.localizedDescription }
    }

    // MARK: Actions

    func setSeen(_ messages: [MessageSummary], _ seen: Bool) async {
        for m in messages where m.seen != seen {
            // Offline or no password: keep the state locally, the next sync settles it with the server.
            do { try await sync.setSeen(m, seen) } catch { try? store.setSeen(id: m.id, seen) }
        }
        reload()
    }

    func markThread(_ m: MessageSummary, seen: Bool) async { await setSeen(thread(m), seen) }

    /// Archive (or Gmail "All Mail") of the message's account; nil when the account has neither.
    func archiveFolder(_ m: MessageSummary) -> String? {
        let f = store.folders(account: m.accountID)
        return (f.first { $0.role == .archive } ?? f.first { $0.role == .all })?.path
    }

    func archive(_ m: MessageSummary) async {
        guard let target = archiveFolder(m) else { lastError = "Účet nemá priečinok Archív."; return }
        await move(thread(m).filter { $0.folder != target }, to: target)
    }

    func trash(_ m: MessageSummary) async {
        guard let target = store.folders(account: m.accountID).first(where: { $0.role == .trash })?.path else { lastError = "Účet nemá Kôš."; return }
        await move(thread(m).filter { $0.folder != target }, to: target)
    }

    private func move(_ list: [MessageSummary], to target: String) async {
        do { try await sync.move(list, to: target) } catch { lastError = error.localizedDescription }
        reload()
    }

    // MARK: Accounts & sending

    func addAccount(email: String, name: String, secret: String, log: @escaping @Sendable (String) -> Void) async throws {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard let cfg = await Autoconfig.discover(email: mail, log: log) else {
            throw MailError.notFound("nenašiel som nastavenia servera pre \(mail)")
        }
        log("Prihlasujem sa na \(cfg.imap.host)…")
        let client = try await MailSync.connect(cfg.imap, secret: secret)
        await client.logout()
        let a = Account(email: mail, name: name.isEmpty ? mail : name, imap: cfg.imap, smtp: cfg.smtp, sort: accounts.count)
        try Keychain.set(secret, for: a.id)
        try store.save(a)
        reload()
        log("Sťahujem poštu…")
        try? await sync.syncFolders(a)
        for f in store.folders(account: a.id) where f.selectable && [.inbox, .sent].contains(f.role) {
            try? await sync.syncMessages(a, folder: f.path)
        }
        reload()
    }

    func removeAccount(_ a: Account) {
        Keychain.delete(a.id)
        try? store.deleteAccount(a.id)
        reload()
    }

    func send(_ m: OutgoingMessage) async throws {
        try await sync.send(m)
        reload()
    }

    func replyHeaders(_ m: MessageSummary) -> (inReplyTo: String, references: [String]) {
        let h = store.threadHeaders(id: m.id)
        return (h.messageID, h.references + [h.messageID])
    }
}
#endif
