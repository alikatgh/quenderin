import XCTest
@testable import QuenderinKit

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

    func testDegenerationDropsTheCrossingTokenAndSuppressesContinue() async {
        let word = String(repeating: "a", count: 100)
        let prefix = Array(repeating: word, count: 31)   // degenerate at the 32nd checkpoint
        let tokens = prefix + ["CROSSING"] + Array(repeating: "LEAK", count: 40)
        let chat = ChatModel(engine: await loadedMock(tokens.joined(separator: " ")))

        // maxTokens equals the trip count, so the Continue path WOULD fire without `!hitDegeneration`.
        await chat.send("loop", options: GenerationOptions(maxTokens: 32))

        let text = chat.messages.last?.text ?? ""
        XCTAssertEqual(text, prefix.joined(separator: " "), "the crossing token must be excluded")
        XCTAssertFalse(text.contains("CROSSING"))
        XCTAssertFalse(text.contains("LEAK"), "pieces after the break must never be consumed")
        XCTAssertFalse(chat.lastHitTokenCap, "degeneration must never offer Continue")
        XCTAssertFalse(chat.isGenerating)
    }
}
