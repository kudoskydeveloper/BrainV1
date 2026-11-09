import Testing
import Foundation
@testable import CourierCore

/// A store with one account whose Drafts and Sent hold the given messages.
private func storeWithDrafts(_ drafts: [Store.HeaderRow]) throws -> Store {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("courier-test-\(UUID().uuidString).sqlite")
    let store = try Store(path: url)
    try store.replaceFolders(account: "a", [
        Folder(accountID: "a", path: "INBOX", name: "INBOX", delimiter: "/", role: .inbox, unread: 0, total: 0, selectable: true),
        Folder(accountID: "a", path: "Drafts", name: "Drafts", delimiter: "/", role: .drafts, unread: 0, total: 0, selectable: true),
        Folder(accountID: "a", path: "Sent", name: "Sent", delimiter: "/", role: .sent, unread: 0, total: 0, selectable: true),
    ])
    try store.upsertHeaders(account: "a", folder: "Drafts", drafts, windowStart: 0)
    return store
}

private func row(_ uid: UInt32, _ mid: String, _ subject: String, to: String) -> Store.HeaderRow {
    Store.HeaderRow(uid: uid, messageID: mid, subject: subject, from: EmailAddress(name: "", address: "me@x.sk"), to: to, cc: "",
                    date: Date(), seen: true, flagged: false, answered: false, size: 100, hasAttachments: false)
}

@Test func sentDraftLeavesLocalDrafts() throws {
    let store = try storeWithDrafts([row(1, "d1@courier.local", "Ponuka", to: "jan@x.sk"), row(2, "d2@courier.local", "Iné", to: "eva@x.sk")])
    // Message-ID as the composer has it (any case): only that draft goes
    try store.deleteMessages(account: "a", folder: "Drafts", messageID: "D1@courier.local")
    #expect(store.message(messageID: "d1@courier.local", account: "a") == nil)
    #expect(store.message(messageID: "d2@courier.local", account: "a") != nil)
    // an empty id never wipes the folder
    try store.deleteMessages(account: "a", folder: "Drafts", messageID: "")
    #expect(store.message(messageID: "d2@courier.local", account: "a") != nil)
}

@Test func sendingFindsItsDraft() throws {
    let store = try storeWithDrafts([
        row(1, "d1@courier.local", "Ponuka", to: "Ján Novák <jan@x.sk>"),
        row(2, "d2@courier.local", "Ponuka", to: "eva@x.sk, petra@x.sk"),
        row(3, "d3@courier.local", "Dvakrát", to: "jan@x.sk"),
        row(4, "d4@courier.local", "Dvakrát", to: "jan@x.sk"),
    ])
    // same subject and To (names and case do not matter) → that draft
    #expect(store.matchingDraft(account: "a", subject: "Ponuka", to: [EmailAddress(name: "", address: "JAN@x.sk")])?.uid == 1)
    #expect(store.matchingDraft(account: "a", subject: "Ponuka", to: MIME.parseAddresses("petra@x.sk, eva@x.sk"))?.uid == 2)
    // different recipients, another subject or another account → none
    #expect(store.matchingDraft(account: "a", subject: "Ponuka", to: [EmailAddress(name: "", address: "eva@x.sk")]) == nil)
    #expect(store.matchingDraft(account: "a", subject: "Re: Ponuka", to: [EmailAddress(name: "", address: "jan@x.sk")]) == nil)
    #expect(store.matchingDraft(account: "b", subject: "Ponuka", to: [EmailAddress(name: "", address: "jan@x.sk")]) == nil)
    // two drafts look the same → guessing could remove the wrong one, so none
    #expect(store.matchingDraft(account: "a", subject: "Dvakrát", to: [EmailAddress(name: "", address: "jan@x.sk")]) == nil)
}

@Test func gmailSpecialUseBeatsLabelNamedLikeIt() {
    func f(_ path: String, _ role: FolderRole) -> Folder {
        Folder(accountID: "g", path: path, name: path, delimiter: "/", role: role, unread: 0, total: 0, selectable: true)
    }
    // a Slovak Gmail: user labels "Koncepty" / "Odoslan&AOk-" are only named like the real folders
    let out = MailSync.dedupeRoles([f("Koncepty", .drafts), f("Odoslan&AOk-", .sent),
                                    f("[Gmail]/Rozp&AO0-san&AOk- spr&AOE-vy", .drafts), f("[Gmail]/Odoslan&AOk-", .sent)],
                                   marked: ["[Gmail]/Rozp&AO0-san&AOk- spr&AOE-vy", "[Gmail]/Odoslan&AOk-"])
    let role = Dictionary(uniqueKeysWithValues: out.map { ($0.path, $0.role) })
    #expect(role["[Gmail]/Rozp&AO0-san&AOk- spr&AOE-vy"] == .drafts)
    #expect(role["[Gmail]/Odoslan&AOk-"] == .sent)
    #expect(role["Koncepty"] == .other && role["Odoslan&AOk-"] == .other)
    // without SPECIAL-USE (a plain IMAP server) the name still decides
    #expect(MailSync.dedupeRoles([f("INBOX.Drafts", .drafts), f("Drafts", .drafts)]).first { $0.path == "Drafts" }?.role == .drafts)
}
