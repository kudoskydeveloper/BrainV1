import XCTest
@testable import BrainCore

final class StreamTests: XCTestCase {
    func testInitAssistantAndResult() {
        XCTAssertEqual(StreamParser.parse(#"{"type":"system","subtype":"init","session_id":"s1","mcp_servers":[{"name":"brain","status":"connected"}]}"#),
                       [.started(session: "s1", brainConnected: true)])
        XCTAssertEqual(StreamParser.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__brain__where_is","input":{}},{"type":"text","text":"Found it"}]}}"#),
                       [.usingTool("where_is"), .text("Found it")])
        XCTAssertEqual(StreamParser.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done","session_id":"s1"}"#),
                       [.finished(result: "Done", session: "s1", isError: false)])
    }

    func testRawControlCharactersInsideStrings() {
        let line = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"line one\u{1}\tline two\",\"session_id\":\"s\"}"
        XCTAssertEqual(StreamParser.parse(line).count, 1)
    }

    func testJunkAndLogin() {
        XCTAssertEqual(StreamParser.parse("Warning: no stdin data received"), [])
        XCTAssertEqual(StreamParser.parse(#"{"type":"user","message":{}}"#), [])
        XCTAssertTrue(StreamParser.needsLogin("Failed to authenticate: OAuth session expired and could not be refreshed"))
        XCTAssertFalse(StreamParser.needsLogin("Your Kudosky one pager is in iCloud Drive"))
    }

    func testLimitAndAccountEmail() {
        XCTAssertTrue(StreamParser.limitReached("Claude AI usage limit reached|1762365600"))
        XCTAssertTrue(StreamParser.limitReached("You've hit your limit · resets 9pm"))
        XCTAssertFalse(StreamParser.limitReached("Limit order placed for AAPL"))
        XCTAssertEqual(Runner.validEmail(" hello@firma2.example "), "hello@firma2.example")
        XCTAssertNil(Runner.validEmail("x@y.sk'; rm -rf ~"))
        XCTAssertNil(Runner.validEmail(nil))
    }

    func testProposalFromToolResult() {
        let inner = #"{\"needs_confirm\": true, \"proposal_id\": \"brain_ab12cd34\", \"summary\": \"WhatsApp to Jana: idem domov\", \"next\": \"...\"}"#
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":""# + inner + #""}]}]}}"#
        XCTAssertEqual(StreamParser.parse(line), [.proposal(id: "brain_ab12cd34", summary: "WhatsApp to Jana: idem domov")])
        XCTAssertEqual(StreamParser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"{\"ok\":true}"}]}}"#), [])
    }

    func testProposalAsBrainRendersIt() {
        // a real tool result from a Brain transcript
        let text = "**Čaká na tvoje potvrdenie**\n\nWhatsApp to Peter Kováč (cez Beeper, odošle sa po tvojom áno):\n\"tu je môj mail: ja@praca.example\"\n\nproposal: `brain_d398655d`\n_Show this summary to the user. Call confirm with the proposal_id only after they say yes. Expires in 15 minutes._"
        let line = String(data: try! JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": [["type": "tool_result", "content": [["type": "text", "text": text]]]]]]), encoding: .utf8)!
        XCTAssertEqual(StreamParser.parse(line), [.proposal(id: "brain_d398655d",
            summary: "WhatsApp to Peter Kováč (cez Beeper, odošle sa po tvojom áno):\n\"tu je môj mail: ja@praca.example\"")])
    }
}
