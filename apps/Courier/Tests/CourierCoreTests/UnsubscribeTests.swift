import Foundation
import Testing
@testable import CourierCore

@Suite struct UnsubscribeTests {
    @Test func oneClickWinsWhenPostHeaderIsThere() {
        let s = Unsubscribe.encode(header: "<mailto:u@list.example.com?subject=unsub>, <https://list.example.com/u/abc>",
                                   post: "List-Unsubscribe=One-Click")
        let m = Unsubscribe.method(stored: s, sender: "news@example.com")
        #expect(m?.kind == .oneClick)
        #expect(m?.url.absoluteString == "https://list.example.com/u/abc")
    }

    @Test func mailWithoutOneClick() {
        let s = Unsubscribe.encode(header: "<https://list.example.com/u/abc>, <mailto:u@list.example.com?subject=Odhlasit>", post: "")
        let m = Unsubscribe.method(stored: s, sender: "news@example.com")
        #expect(m?.kind == .mail)
        let t = Unsubscribe.mailto(m!.url)
        #expect(t.to == "u@list.example.com")
        #expect(t.subject == "Odhlasit")
    }

    @Test func webOnly() {
        let s = Unsubscribe.encode(header: "<https://example.com/prefs?id=1>", post: "")
        #expect(Unsubscribe.method(stored: s, sender: "a@b.c")?.kind == .web)
    }

    @Test func foldedHeaderAndNone() {
        let s = Unsubscribe.encode(header: "<https://example.com/u/\r\n abc>", post: "List-Unsubscribe=One-Click")
        #expect(Unsubscribe.method(stored: s, sender: "a@b.c")?.url.absoluteString == "https://example.com/u/abc")
        #expect(Unsubscribe.method(stored: "", sender: "a@b.c") == nil)
    }

    @Test func fromRawMessage() {
        let raw = Data("From: a@b.c\r\nList-Unsubscribe: <https://x.example/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\nbody".utf8)
        #expect(Unsubscribe.method(stored: Unsubscribe.fromRaw(raw), sender: "a@b.c")?.kind == .oneClick)
    }
}
