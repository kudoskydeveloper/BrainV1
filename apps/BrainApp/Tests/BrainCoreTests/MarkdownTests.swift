import XCTest
@testable import BrainCore

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let md = """
        ## Dnes
        Krátky **úvod**.

        - prvá
          pokračovanie
        - [ ] úloha
        - [x] hotové
        1. jeden

        > Dobrý deň,
        > ďakujem.

        | Čas | Kto |
        |---|---|
        | 13:00 | Hanula |
        ---
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .heading(level: 2, text: "Dnes"),
            .paragraph("Krátky **úvod**."),
            .list([MDListItem(text: "prvá pokračovanie", depth: 0, marker: .bullet),
                   MDListItem(text: "úloha", depth: 0, marker: .task(done: false)),
                   MDListItem(text: "hotové", depth: 0, marker: .task(done: true)),
                   MDListItem(text: "jeden", depth: 0, marker: .number("1"))]),
            .quote("Dobrý deň,\nďakujem."),
            .table(header: ["Čas", "Kto"], rows: [["13:00", "Hanula"]]),
            .rule,
        ])
    }

    func testBoldLineIsNotARuleAndCodeIsKept() {
        XCTAssertEqual(MarkdownBlocks.parse("**Ranný prehľad**\n```\na | b\n```"),
                       [.paragraph("**Ranný prehľad**"), .code("a | b")])
    }

    func testNestedItems() {
        XCTAssertEqual(MarkdownBlocks.parse("- a\n  - b"),
                       [.list([MDListItem(text: "a", depth: 0, marker: .bullet), MDListItem(text: "b", depth: 1, marker: .bullet)])])
    }
}
