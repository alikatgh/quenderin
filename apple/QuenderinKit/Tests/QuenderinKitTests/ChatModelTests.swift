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

    func testSendIgnoresEmptyInput() async {
        let chat = ChatModel(engine: await loadedMock("x"))
        await chat.send("   ")
        XCTAssertTrue(chat.messages.isEmpty)
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
