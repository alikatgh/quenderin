import XCTest
@testable import QuenderinKit

final class ConversationExporterTests: XCTestCase {
    private func msg(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    func testRendersTranscriptWithSpeakersAndTitle() {
        let md = ConversationExporter.markdown([
            msg(.user, "Hello there"),
            msg(.assistant, "Hi — how can I help?"),
        ], title: "My chat")
        XCTAssertTrue(md.hasPrefix("# My chat\n"))
        XCTAssertTrue(md.contains("**You:**\nHello there"))
        XCTAssertTrue(md.contains("**Quenderin:**\nHi — how can I help?"))
        XCTAssertTrue(md.contains("2 messages"))
    }

    func testFallsBackToDefaultTitleAndSingularCount() {
        let md = ConversationExporter.markdown([msg(.user, "Only one")], title: nil)
        XCTAssertTrue(md.hasPrefix("# Conversation\n"))
        XCTAssertTrue(md.contains("1 message."), "singular, not '1 messages'")
    }

    func testEmptyTranscriptStillProducesAHeader() {
        let md = ConversationExporter.markdown([], title: "  ")
        XCTAssertTrue(md.hasPrefix("# Conversation\n"), "blank title falls back to default")
        XCTAssertTrue(md.contains("0 messages"))
        XCTAssertFalse(md.contains("**You:**"))
    }
}
