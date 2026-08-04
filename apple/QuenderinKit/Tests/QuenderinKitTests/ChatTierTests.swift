import XCTest
@testable import QuenderinKit

final class ChatTierTests: XCTestCase {
    func testSizeClasses() {
        XCTAssertEqual(ChatTier.of(paramsBillions: 1.0), .tiny)
        XCTAssertEqual(ChatTier.of(paramsBillions: 4.0), .small)
        XCTAssertEqual(ChatTier.of(paramsBillions: 7.0), .full)
    }

    func testMaxTokensOrder() {
        XCTAssertLessThan(ChatTier.tiny.maxTokens, ChatTier.small.maxTokens)
        XCTAssertLessThan(ChatTier.small.maxTokens, ChatTier.full.maxTokens)
        XCTAssertEqual(ChatTier.full.maxTokens, 512)
    }

    func testTinySuffixTightens() {
        XCTAssertTrue(ChatTier.tiny.systemPrompt.contains("8 short sentences"))
        XCTAssertTrue(ChatTier.tiny.systemPrompt.contains("Always reply in the same language"))
        XCTAssertFalse(ChatTier.full.systemPromptSuffix.isEmpty == false && ChatTier.full.systemPromptSuffix.count > 50)
        XCTAssertEqual(ChatTier.full.systemPromptSuffix, "")
    }
}
