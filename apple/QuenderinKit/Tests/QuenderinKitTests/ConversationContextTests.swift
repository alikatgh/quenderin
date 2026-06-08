import XCTest
@testable import QuenderinKit

final class ConversationContextTests: XCTestCase {

    private func u(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    private func a(_ t: String) -> ChatMessage { ChatMessage(role: .assistant, text: t) }

    func testIncludesSystemPromptAndAssistantPrimer() {
        let prompt = ConversationContext().build(history: [u("hello")])
        XCTAssertTrue(prompt.contains("Quenderin"), "system prompt should lead the prompt")
        XCTAssertTrue(prompt.contains("User: hello"))
        XCTAssertTrue(prompt.hasSuffix("Assistant:"), "should end primed for the assistant's turn")
    }

    func testRetainsMultiTurnHistoryInOrder() {
        // The amnesia fix: every prior turn must survive into the prompt, chronologically.
        let prompt = ConversationContext().build(history: [u("a"), a("b"), u("c")])
        XCTAssertTrue(prompt.contains("User: a"))
        XCTAssertTrue(prompt.contains("Assistant: b"))
        XCTAssertTrue(prompt.contains("User: c"))
        let first = prompt.range(of: "User: a")!.lowerBound
        let last = prompt.range(of: "User: c")!.lowerBound
        XCTAssertLessThan(first, last, "history must stay chronological")
    }

    func testBudgetDropsOldestKeepsNewest() {
        let ctx = ConversationContext(systemPrompt: "", contextTokens: 80, reservedForResponse: 0)
        let history = (1...20).map { u("message number \($0) here") }
        let prompt = ctx.build(history: history)
        XCTAssertFalse(prompt.contains("message number 1 here"), "oldest turn should fall off past budget")
        XCTAssertTrue(prompt.contains("message number 20 here"), "newest turn must be kept")
    }

    func testLatestTurnKeptEvenIfItAloneExceedsBudget() {
        let ctx = ConversationContext(systemPrompt: "", contextTokens: 4, reservedForResponse: 0)
        let prompt = ctx.build(history: [u("a single message far larger than the tiny budget allows")])
        XCTAssertTrue(prompt.contains("a single message far larger"), "never drop the user's current turn")
    }

    func testEmptySystemPromptIsOmitted() {
        let prompt = ConversationContext(systemPrompt: "").build(history: [u("hi")])
        XCTAssertTrue(prompt.hasPrefix("User: hi"), "no leading blank lines when there is no system prompt")
    }
}
