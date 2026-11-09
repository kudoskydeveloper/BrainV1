import Testing
import Foundation
@testable import CourierCore

@Test func parsesFetchWithLiteral() {
    let raw = Data("* 3 FETCH (UID 42 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM SUBJECT)] {29}\r\nSubject: Ahoj\r\nFrom: a@b.c\r\n\r\n)\r\n".utf8)
    let v = IMAPParser.parse(raw)
    #expect(v[2].text == "FETCH")
    let items = v[3].list!
    #expect(items[0].text == "UID" && items[1].text == "42")
    #expect(items[4].text == "BODY[HEADER.FIELDS (FROM SUBJECT)]")
    #expect(items[5].text?.contains("Subject: Ahoj") == true)
}

@Test func decodesEncodedWords() {
    #expect(MIME.decodeWords("=?UTF-8?B?xb5sdcWlb3XEjWvDvQ==?= kôň") == "žluťoučký kôň")
    #expect(MIME.decodeWords("=?iso-8859-2?Q?Pr=ED=B9ern=EC?= =?iso-8859-2?Q?_test?=") == "Príšerně test")
}

@Test func modifiedUTF7() {
    #expect(ModifiedUTF7.decode("Odoslan&AOk-") == "Odoslané")
    #expect(ModifiedUTF7.encode("Kôš") == ModifiedUTF7.encode(ModifiedUTF7.decode(ModifiedUTF7.encode("Kôš"))))
    #expect(ModifiedUTF7.decode(ModifiedUTF7.encode("Kôš & spol")) == "Kôš & spol")
}

@Test func parsesMultipart() {
    let msg = """
    From: "Ján Novák" <jan@example.sk>
    To: a@b.c, "X, Y" <x@y.z>
    Subject: =?utf-8?Q?Faktúra?=
    Date: Thu, 5 Nov 2026 10:00:00 +0100 (CET)
    Content-Type: multipart/mixed; boundary="b1"

    --b1
    Content-Type: multipart/alternative; boundary=b2

    --b2
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Dobr=C3=BD de=
    =C5=88
    --b2
    Content-Type: text/html; charset=utf-8

    <p>Dobrý deň</p>
    --b2--
    --b1
    Content-Type: application/pdf; name="f.pdf"
    Content-Disposition: attachment; filename*=UTF-8''fakt%C3%BAra.pdf
    Content-Transfer-Encoding: base64

    JVBERi0=
    --b1--
    """.replacingOccurrences(of: "\n", with: "\r\n")
    let m = MIME.parseMessage(Data(msg.utf8))
    #expect(m.subject == "Faktúra")
    #expect(m.from.first?.name == "Ján Novák")
    #expect(m.to.count == 2)
    #expect(m.text == "Dobrý deň")
    #expect(m.html?.contains("Dobrý deň") == true)
    #expect(m.attachments.first?.filename == "faktúra.pdf")
    #expect(m.attachments.first?.size == 5)
    #expect(m.date != nil)
}
