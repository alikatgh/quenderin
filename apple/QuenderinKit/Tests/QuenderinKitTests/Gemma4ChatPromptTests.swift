import XCTest
@testable import QuenderinKit

final class Gemma4ChatPromptTests: XCTestCase {
    func testNativeRolesAndClosedThinkingChannel() throws {
        let prompt = try XCTUnwrap(Gemma4ChatPrompt.make(
            template: "<|turn> <|channel> enable_thinking", system: "Be concise.",
            history: [.init(role: .user, text: "Hello"), .init(role: .assistant, text: "Hi"),
                      .init(role: .user, text: "Again")] ))
        XCTAssertTrue(prompt.hasPrefix("<|turn>system\nBe concise.<turn|>\n"))
        XCTAssertTrue(prompt.contains("<|turn>user\nHello<turn|>\n<|turn>model\nHi<turn|>\n"))
        XCTAssertTrue(prompt.hasSuffix("<|turn>user\nAgain<turn|>\n<|turn>model\n<|channel>thought\n<channel|>"))
        XCTAssertFalse(prompt.contains("<think>"), "Gemma must not receive Qwen's thinking syntax")
    }

    func testOtherModelTemplatesStayOnTheirExistingPath() {
        for template in ["<start_of_turn>user", "<|im_start|> enable_thinking <think>", "[INST]"] {
            XCTAssertNil(Gemma4ChatPrompt.make(template: template, system: "", history: []))
        }
    }

    func testRealGemmaChatDoesNotExposeProtocolMarkers() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUENDERIN_GEMMA_MODEL"] else {
            throw XCTSkip("set QUENDERIN_GEMMA_MODEL for real Gemma 4 validation")
        }
        let engine = LlamaEngine()
        try await engine.load(model: XCTUnwrap(ModelCatalog.entry(id: "gemma4-12b")), at: URL(fileURLWithPath: path))
        var reply = ""
        let stream = try await engine.generateChat(system: "Answer briefly.", history: [
            .init(role: .user, text: "Reply with one short sentence about a quiet mountain lake.")
        ], options: .init(maxTokens: 80, temperature: 0))
        for try await piece in stream { reply += piece }
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        for marker in ["<|channel>", "<channel|>", "<|turn>", "<turn|>", "<think>"] {
            XCTAssertFalse(reply.contains(marker), "Protocol marker in reply: \(reply)")
        }
        print("GEMMA_RELEASE_QA_REPLY: \(reply)")
        await engine.unload()
    }
}
