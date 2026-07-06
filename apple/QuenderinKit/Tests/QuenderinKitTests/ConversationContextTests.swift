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

    // Q-167: chat history is trimmed to the engine's REAL loaded n_ctx, not a hardcoded 4096.
    // Twin of the CoreVerify "windowedHistory trims to the smaller real n_ctx override" check —
    // the override existed only on Android until the twin-drift audit.
    func testWindowedHistoryTrimsToRealContextOverride() {
        // Six ~10-token turns. A 4096-token window keeps them all; the real phone window (a small
        // n_ctx) must drop the oldest — proving the override, not the fixed 4096, drives the trim.
        let ctx = ConversationContext(systemPrompt: "", reservedForResponse: 0)
        let history = (1...6).map { i in
            ChatMessage(role: i % 2 == 1 ? .user : .assistant, text: "message number \(i) goes here now")
        }
        let big = ctx.windowedHistory(history, contextTokensOverride: 4096)
        let small = ctx.windowedHistory(history, contextTokensOverride: 48)   // ~48-token native window
        XCTAssertEqual(big.count, history.count, "roomy window keeps everything")
        XCTAssertLessThan(small.count, history.count, "tight real window drops the oldest")
        XCTAssertEqual(small.last, history.last, "newest turn always kept")
        XCTAssertEqual(ctx.windowedHistory(history, contextTokensOverride: nil).count, history.count,
                       "nil falls back to the configured contextTokens")
    }
}
