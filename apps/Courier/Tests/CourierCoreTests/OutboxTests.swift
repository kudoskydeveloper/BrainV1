import Testing
import Foundation
@testable import CourierCore

@Test func outboxUndoAndSchedule() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("courier-test-\(UUID().uuidString).sqlite")
    let store = try Store(path: url)
    let m = OutgoingMessage(accountID: "a", to: [EmailAddress(name: "Ján", address: "jan@x.sk")], subject: "Ahoj", body: "Text")
    let soon = try store.enqueue(m, at: Date().addingTimeInterval(10))
    let later = try store.enqueue(m, at: Date().addingTimeInterval(86400))
    #expect(store.outbox().count == 2)
    #expect(!soon.scheduled && later.scheduled)
    #expect(store.dequeue(soon.id) != nil)        // undo
    #expect(store.dequeue(soon.id) == nil)        // already gone: too late to undo twice
    #expect(store.outbox().map(\.id) == [later.id])
}

@Test func htmlSignatureBuildsAlternative() throws {
    var m = OutgoingMessage(accountID: "a", to: [EmailAddress(name: "", address: "jan@x.sk")], subject: "Čau", body: "")
    m.compose(text: "Ahoj Ján", signature: Signature(name: "S", body: "<b>Ján</b>", isHTML: true), quoted: "Dňa … napísal:\n> pôvodné")
    #expect(m.body.contains("Ahoj Ján") && m.body.contains("Ján") && m.body.contains("> pôvodné"))
    let raw = try MessageBuilder.build(m, from: EmailAddress(name: "Ján", address: "m@x.sk"))
    #expect(raw.contains("multipart/alternative"))
    #expect(raw.contains("Subject: =?UTF-8?B?"))
    let parsed = MIME.parseMessage(Data(raw.utf8))
    #expect(parsed.text?.contains("Ahoj Ján") == true)
    #expect(parsed.html?.contains("<b>Ján</b>") == true)
    #expect(parsed.subject == "Čau")
}

@Test func queuedMessageKeepsComposerState() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("courier-test-\(UUID().uuidString).sqlite")
    let store = try Store(path: url)
    var m = OutgoingMessage(accountID: "a", to: [EmailAddress(name: "", address: "jan@x.sk")], subject: "Re: Ponuka", body: "")
    let sig = Signature(name: "S", body: "Ján")
    m.compose(text: "Posielam ponuku.", signature: sig, quoted: "Dňa … napísal:\n> otázka")
    m.composerText = "Posielam ponuku."; m.quoted = "Dňa … napísal:\n> otázka"; m.signatureID = sig.id
    let when = Date().addingTimeInterval(3600)
    let item = try store.enqueue(m, at: when)
    let back = try #require(store.outbox().first { $0.id == item.id })
    #expect(back.message.composerText == "Posielam ponuku.")
    #expect(back.message.quoted == "Dňa … napísal:\n> otázka")
    #expect(back.message.signatureID == sig.id)
    #expect(abs(back.sendAt.timeIntervalSince(when)) < 1)
    #expect(back.scheduled)
}
