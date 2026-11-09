import Testing
@testable import CourierCore

@Test func classifiesMail() {
    #expect(MailCategory.classify(from: "Ján Novák <jan@firma.sk>", subject: "Stretnutie zajtra", headers: [:]) == .people)
    #expect(MailCategory.classify(from: "Supabase <hello@mail.supabase.io>", subject: "Supa Update",
                                  headers: ["list-unsubscribe": "<https://x>", "precedence": "bulk"]) == .newsletters)
    #expect(MailCategory.classify(from: "GitHub <notifications@github.com>", subject: "[repo] PR merged",
                                  headers: ["list-unsubscribe": "<mailto:x>"]) == .notifications)
    #expect(MailCategory.classify(from: "Todoist <no-reply@todoist.com>", subject: "David joined", headers: [:]) == .notifications)
    #expect(MailCategory.classify(from: "Websupport <fakturacia@hosting.sk>", subject: "Faktúra 126309150", headers: ["list-unsubscribe": "x"]) == .invoices)
    #expect(MailCategory.classify(from: "Zuzana <z@partner.sk>", subject: "Accepted: Stretnutie Kudosky", headers: [:]) == .invites)
    #expect(MailCategory.classify(from: "x@y.sk", subject: "Ahoj", headers: [:], hasCalendar: true) == .invites)
    #expect(MailCategory.classify(from: "noreply@x.sk", subject: "Hi", headers: [:], isMine: true) == .people)
}
