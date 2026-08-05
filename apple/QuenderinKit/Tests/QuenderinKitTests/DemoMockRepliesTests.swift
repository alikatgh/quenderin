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
