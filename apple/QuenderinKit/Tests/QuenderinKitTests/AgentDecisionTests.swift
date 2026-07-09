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

    /// Live-caught: Llama 1B copied the prompt template `{"tool":"<name>","input":"<text>"}`
    /// and stalled on "No such tool: <name>". Placeholders must fail parse so the loop nudges.
    func testRejectsPlaceholderToolNames() {
        XCTAssertTrue(AgentDecisionParser.isPlaceholderToolName("<name>"))
        XCTAssertTrue(AgentDecisionParser.isPlaceholderToolName("name"))
        XCTAssertTrue(AgentDecisionParser.isPlaceholderToolName("<text>"))
        XCTAssertFalse(AgentDecisionParser.isPlaceholderToolName("mac.calendar.add"))
        XCTAssertNil(AgentDecisionParser.parse(#"{"tool":"<name>","input":"<text>"}"#))
        XCTAssertNil(AgentDecisionParser.parse(#"{"tool":"name","input":"x"}"#))
        XCTAssertNil(AgentDecisionParser.parse(
            #"{"plan":[{"tool":"<name>","input":"x"},{"tool":"calculator","input":"1"}]}"#))
    }
}
