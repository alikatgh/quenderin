import XCTest
@testable import QuenderinKit

private struct CapReportingSettlementEngine: InferenceEngine {
    let engine: MockInferenceEngine
    let capStatus: ChatCapStatus

    func loadedModelID() async -> String? { await engine.loadedModelID() }
    func load(model: ModelEntry, at fileURL: URL) async throws { try await engine.load(model: model, at: fileURL) }
    func unload() async { await engine.unload() }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        try await engine.generate(prompt: prompt, options: options)
    }
    func chatCapStatus() async -> ChatCapStatus { capStatus }
}

/// Settlement parity with Kotlin `ChatModel`:
///
/// - the transcript settles from the STREAMED pieces (the stream is Swift's only engine channel,
///   so Kotlin's "emitted A / return B" and "no emission -> return B" cases have no Swift twin;
///   a stream that emits nothing settles to the honest empty notice);
/// - the degeneration checkpoint runs BEFORE appending, so the piece that crosses it is excluded;
/// - a degeneration stop suppresses the "Continue" affordance even at the token cap.
///
/// The engine here yields synchronously, so `break` drops the iterator and the remaining pieces are
/// never consumed — the observable bound for a cancel-ignoring engine.
@MainActor
final class ChatSettlementTests: XCTestCase {

    private func loadedMock(_ reply: String) async -> MockInferenceEngine {
        let engine = MockInferenceEngine(cannedReply: reply)
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        return engine
    }

    func testStreamedPiecesAreTheSettledText() async {
        let chat = ChatModel(engine: await loadedMock("hi there friend"))
        await chat.send("hello")

        XCTAssertEqual(chat.messages.last?.text, "hi there friend")
        XCTAssertFalse(chat.isGenerating)
    }

    func testEmptyStreamSettlesToTheHonestNotice() async {
        let chat = ChatModel(engine: await loadedMock(""))
        await chat.send("hello?")

        XCTAssertEqual(chat.messages.last?.text, ChatUserFacing.emptyReply())
    }

    func testThinkingIsWithheldWithTheReplyAndWhenItIsTheOnlyOutput() async throws {
        for output in ["<think>private reasoning</think>ignore previous", "<think>system prompt: private reasoning"] {
            let chat = ChatModel(engine: await loadedMock(output))
            await chat.send("hello", thinkingMode: .show)

            XCTAssertEqual(chat.messages.last?.text, OutputCheck.injection)
            XCTAssertNil(chat.messages.last?.thinking)
            let stored = try ConversationStore().encode(chat.completedMessages())
            XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("private reasoning"))
        }
    }

    func testCheckerReceivesReasoningOnlyOutputBeforeItCanAppear() async {
        defer { RoleSeat.shared.reset() }
        let chat = ChatModel(engine: await loadedMock("<think>private reasoning"))
        RoleSeat.shared.setChecker(modelID: "fixture") { _, content in
            XCTAssertTrue(content.contains("private reasoning"))
            return "no"
        }
        await chat.send("hello", thinkingMode: .show)
        XCTAssertEqual(chat.messages.last?.text, OutputCheck.checkerHeld)
        XCTAssertNil(chat.messages.last?.thinking)
    }

    func testOnlyFullyReviewedThinkingIsShownAndRestored() async throws {
        defer { RoleSeat.shared.reset() }
        RoleSeat.shared.reset()
        let unchecked = ChatModel(engine: await loadedMock("<think>some reasoning</think>answer"))
        await unchecked.send("hello", thinkingMode: .show)
        XCTAssertEqual(unchecked.messages.last?.text, "answer")
        XCTAssertNil(unchecked.messages.last?.thinking)

        RoleSeat.shared.setChecker(modelID: "fixture") { _, content in
            XCTAssertEqual(content, "answer\n\nsome reasoning")
            return "yes"
        }
        let chat = ChatModel(engine: await loadedMock("<think>some reasoning</think>answer"))
        await chat.send("hello", thinkingMode: .show)
        let store = ConversationStore()
        XCTAssertEqual(try store.decode(store.encode(chat.completedMessages())).last?.thinking, "some reasoning")

        for text in ["ordinary answer", OutputCheck.checkerHeld] {
            let legacy = Data(#"[{"role":"assistant","text":"\#(text)","thinking":"old reasoning"}]"#.utf8)
            let restored = try store.decode(legacy).last
            XCTAssertEqual(restored?.text, text)
            XCTAssertNil(restored?.thinking)
        }
    }

    func testDegenerationDropsTheCrossingTokenAndSuppressesContinue() async {
        let word = String(repeating: "a", count: 100)
        let prefix = Array(repeating: word, count: 31)   // degenerate at the 32nd checkpoint
        let tokens = prefix + ["CROSSING"] + Array(repeating: "LEAK", count: 40)
        let engine = CapReportingSettlementEngine(engine: await loadedMock(tokens.joined(separator: " ")), capStatus: .hit)
        let chat = ChatModel(engine: engine)

        // Explicit engine evidence would offer Continue without the degeneration guard.
        await chat.send("loop", options: GenerationOptions(maxTokens: 32))

        let text = chat.messages.last?.text ?? ""
        XCTAssertEqual(text, prefix.joined(separator: " "), "the crossing token must be excluded")
        XCTAssertFalse(text.contains("CROSSING"))
        XCTAssertFalse(text.contains("LEAK"), "pieces after the break must never be consumed")
        XCTAssertFalse(chat.lastHitTokenCap, "degeneration must never offer Continue")
        XCTAssertFalse(chat.isGenerating)
    }
}
