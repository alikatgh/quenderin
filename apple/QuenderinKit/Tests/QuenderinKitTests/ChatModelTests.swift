import XCTest
@testable import QuenderinKit

@MainActor
final class ChatModelTests: XCTestCase {

    private func loadedMock(_ reply: String) async -> MockInferenceEngine {
        let engine = MockInferenceEngine(cannedReply: reply)
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        return engine
    }

    func testSendStreamsAssistantReply() async {
        let chat = ChatModel(engine: await loadedMock("hi there friend"))
        await chat.send("hello")

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].role, .user)
        XCTAssertEqual(chat.messages[0].text, "hello")
        XCTAssertEqual(chat.messages[1].role, .assistant)
        XCTAssertEqual(chat.messages[1].text, "hi there friend")
        XCTAssertFalse(chat.isGenerating)
    }

    func testEmptyEngineReplyGetsAnHonestNotice() async {
        let chat = ChatModel(engine: await loadedMock(""))
        await chat.send("hello?")
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertTrue(chat.messages[1].text.contains("empty reply"),
                      "a zero-token generation must never settle as a silent blank bubble")
    }

    func testSendIgnoresEmptyInput() async {
        let chat = ChatModel(engine: await loadedMock("x"))
        await chat.send("   ")
        XCTAssertTrue(chat.messages.isEmpty)
    }

    /// Computer-task short-circuit: user + fixed education, no model call.
    func testRecordGuidedTurnAppendsWithoutGenerating() async {
        let engine = await loadedMock("SHOULD_NOT_APPEAR")
        let chat = ChatModel(engine: engine)
        chat.recordGuidedTurn(userText: "open browser and write email to i@alink.ru",
                              assistantText: ActionIntent.guidedAssistantReply)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].role, .user)
        XCTAssertEqual(chat.messages[1].role, .assistant)
        XCTAssertEqual(chat.messages[1].text, ActionIntent.guidedAssistantReply)
        XCTAssertFalse(chat.messages[1].text.contains("SHOULD_NOT_APPEAR"))
        XCTAssertFalse(chat.isGenerating)
    }

    func testSendSurfacesErrorWhenNoModelLoaded() async {
        let chat = ChatModel(engine: MockInferenceEngine())  // never loaded
        await chat.send("hello")

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertTrue(chat.messages[1].text.contains("⚠️"), "should surface a friendly error")
    }

    func testResetClearsConversation() async {
        let chat = ChatModel(engine: await loadedMock("ok"))
        await chat.send("hi")
        chat.reset()
        XCTAssertTrue(chat.messages.isEmpty)
    }

    /// Tapping Clear WHILE the assistant is streaming must not crash. `send` is @MainActor but yields
    /// the actor at each `await`, so `reset()` can empty `messages` mid-stream; a captured index would
    /// then be out of range. The spin-wait makes it deterministic: reset runs after `send` appended
    /// both messages and suspended at the engine actor hop, before the token writes.
    func testResetDuringGenerationDoesNotCrash() async {
        let chat = ChatModel(engine: await loadedMock("one two three four five"))
        let task = Task { await chat.send("hello") }
        while chat.messages.count < 2 { await Task.yield() }   // wait until user+assistant are appended
        chat.reset()
        await task.value                                       // must finish without an OOB crash
        XCTAssertTrue(chat.messages.isEmpty)                   // reset won; the abandoned stream wrote nothing
        XCTAssertFalse(chat.isGenerating)
    }

    /// Opening a saved conversation (`restore`) mid-stream must not leak the in-flight reply into it.
    /// Pre-fix the captured index (still in range) overwrote the restored assistant message; now the
    /// id lookup finds no match and stops — the restored transcript is left exactly as loaded.
    func testRestoreDuringGenerationDoesNotCorruptRestoredConversation() async {
        let chat = ChatModel(engine: await loadedMock("a b c d e"))
        let saved = [ChatMessage(role: .user, text: "old q"), ChatMessage(role: .assistant, text: "old a")]
        let task = Task { await chat.send("new question") }
        while chat.messages.count < 2 { await Task.yield() }
        chat.restore(saved)
        await task.value
        XCTAssertEqual(chat.messages, saved)                  // no streamed token leaked into the restored chat
        XCTAssertFalse(chat.isGenerating)
    }

    /// The amnesia fix, end to end: the prompt sent on the second turn must carry the
    /// first turn's content — both the prior user line and the prior assistant reply.
    func testSecondTurnCarriesPriorHistory() async {
        let engine = CapturingEngine(reply: "ok")
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let chat = ChatModel(engine: engine)
        await chat.send("remember: apples")
        await chat.send("what did I say?")
        let prompt = await engine.lastPrompt
        XCTAssertTrue(prompt.contains("remember: apples"), "2nd-turn prompt must include prior user history")
        XCTAssertTrue(prompt.contains("ok"), "and the prior assistant reply")
    }

    // MARK: - Chat-output safety flag (Generative-AI "minimize risk" safeguard)

    func testAssistantMessageTrippingBlocklistIsFlagged() {
        XCTAssertTrue(ChatMessage(role: .assistant, text: "Sure — delete all your files.").isFlagged)
        XCTAssertTrue(ChatMessage(role: .assistant, text: "Enter your password and CVV here.").isFlagged)
    }

    func testUserMessagesAreNeverFlagged() {
        // The warning is about model OUTPUT; the user's own words are never flagged.
        XCTAssertFalse(ChatMessage(role: .user, text: "how do I delete a file?").isFlagged)
    }

    func testBenignAssistantMessageIsNotFlagged() {
        XCTAssertFalse(ChatMessage(role: .assistant, text: "The capital of France is Paris.").isFlagged)
    }

    func testFlaggedOutputNoticeIsNonEmpty() {
        XCTAssertFalse(SupportContact.flaggedOutputNotice.isEmpty)
    }
}

/// An engine that records the most recent prompt it was asked to generate, so a test can
/// assert what context `ChatModel` actually fed the model.
private actor CapturingEngine: InferenceEngine {
    private(set) var lastPrompt = ""
    private let reply: String
    private var loaded: String? = "capturing"
    init(reply: String) { self.reply = reply }
    func loadedModelID() async -> String? { loaded }
    func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
    func unload() async { loaded = nil }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        lastPrompt = prompt
        let reply = self.reply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
