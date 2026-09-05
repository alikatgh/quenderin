import XCTest
@testable import QuenderinKit

final class DemoMockRepliesTests: XCTestCase {
    func testMathStarterGetsNumericAnswerAndDemoFooter() {
        let r = DemoMockReplies.reply(for: "What is 17% of 240? Show the arithmetic in one line.")
        XCTAssertTrue(r.contains("40.8"), r)
        XCTAssertTrue(r.lowercased().contains("demo mode"), r)
    }

    func testRussianPromptGetsRussianDemoFooter() {
        let r = DemoMockReplies.reply(for: "Сколько 17% от 240?")
        XCTAssertTrue(r.contains("40"), r)
        XCTAssertTrue(r.contains("Демо") || r.contains("демо"), r)
    }

    func testGenericKeepsHonestDemoCopy() {
        let r = DemoMockReplies.reply(for: "hello there friend")
        XCTAssertTrue(r.lowercased().contains("demo mode") || r.contains("llama"), r)
    }

    /// The mock engine sees the WHOLE flat transcript. Its system prompt mentions "send email", so a
    /// plain "Hello" used to receive the canned email draft. Only the last user turn may decide.
    func testOnlyTheLastUserTurnPicksTheCannedReply() {
        let hello = flatTranscriptPrompt(system: ConversationContext.defaultSystemPrompt,
                                         history: [ChatMessage(role: .user, text: "Hello")])
        let r = DemoMockReplies.reply(for: hello)
        XCTAssertFalse(r.contains("Subject:"), "system-prompt words must not pick the email draft: \(r)")
        XCTAssertTrue(r.lowercased().contains("demo mode"), r)

        // An earlier email turn must not leak into a later math question either.
        let mixed = flatTranscriptPrompt(system: ConversationContext.defaultSystemPrompt, history: [
            ChatMessage(role: .user, text: "Draft a short email declining a meeting."),
            ChatMessage(role: .assistant, text: "Subject: Need to reschedule…"),
            ChatMessage(role: .user, text: "What is 17% of 240?"),
        ])
        XCTAssertTrue(DemoMockReplies.reply(for: mixed).contains("40.8"))
        XCTAssertEqual(DemoMockReplies.lastUserTurn(in: "no markers here"), "no markers here")
    }

    func testMockEngineUsesSmartReplyWhenCannedNil() async throws {
        let engine = MockInferenceEngine()
        try await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let text = try await engine.complete(prompt: "What is 17% of 240?")
        XCTAssertTrue(text.contains("40.8"), text)
    }

    func testMockEngineHonorsExplicitCanned() async throws {
        let engine = MockInferenceEngine(cannedReply: "fixed-reply")
        try await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let text = try await engine.complete(prompt: "What is 17% of 240?")
        XCTAssertEqual(text, "fixed-reply")
    }
}
