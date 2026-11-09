import Testing
import Foundation
@testable import CourierCore

/// Network test: COURIER_LIVE=1 swift test --filter Live
@Test(.enabled(if: ProcessInfo.processInfo.environment["COURIER_LIVE"] != nil))
func liveAutoconfig() async {
    for e in ["test@kudosky.com", "test@daktela.sk", "test@weare10t.com", "test@gmail.com", "test@outlook.com"] {
        let c = await Autoconfig.discover(email: e)
        print("LIVE", e, c.map { "\($0.source) → \($0.imap.host):\($0.imap.port) \($0.imap.security) \($0.imap.auth) user=\($0.imap.username) smtp=\($0.smtp?.host ?? "-")" } ?? "nič")
    }
}
