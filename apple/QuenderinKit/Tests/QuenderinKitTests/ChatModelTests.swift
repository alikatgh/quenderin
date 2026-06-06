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
}
