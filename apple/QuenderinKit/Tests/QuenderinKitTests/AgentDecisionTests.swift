import XCTest
@testable import QuenderinKit

final class AgentDecisionTests: XCTestCase {

    func testParsesToolCall() {
        XCTAssertEqual(
            AgentDecisionParser.parse(#"{"tool":"calculator","input":"2+2"}"#),
            .useTool(name: "calculator", input: "2+2")
        )
    }

    func testParsesFinalAnswer() {
        XCTAssertEqual(AgentDecisionParser.parse(#"{"answer":"42"}"#), .finalAnswer("42"))
    }

    func testParsesJSONWrappedInProse() {
        let raw = #"Sure! Here you go: {"answer":"done"} — hope that helps"#
        XCTAssertEqual(AgentDecisionParser.parse(raw), .finalAnswer("done"))
    }

    func testToolCallWithMissingInputDefaultsToEmpty() {
        XCTAssertEqual(AgentDecisionParser.parse(#"{"tool":"echo"}"#), .useTool(name: "echo", input: ""))
    }

    func testReturnsNilOnNonJSON() {
        XCTAssertNil(AgentDecisionParser.parse("no json here"))
    }
}
