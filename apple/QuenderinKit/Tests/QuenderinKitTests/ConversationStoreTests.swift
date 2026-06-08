import XCTest
@testable import QuenderinKit

@MainActor
final class ConversationStoreTests: XCTestCase {
    private let store = ConversationStore()

    private func u(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    private func a(_ t: String) -> ChatMessage { ChatMessage(role: .assistant, text: t) }

    func testRoundTripPreservesRolesTextAndOrder() throws {
        let original = [u("hi"), a("hello there"), u("bye")]
        let restored = try store.decode(store.encode(original))
        XCTAssertEqual(restored.map(\.role), original.map(\.role))
        XCTAssertEqual(restored.map(\.text), original.map(\.text))
    }

    func testEmptyBlobDecodesToEmptyConversation() throws {
        XCTAssertEqual(try store.decode(Data()).count, 0)
    }

    func testRoundTripSurvivesNewlinesAndSpecialCharacters() throws {
        let tricky = [u("line one\nline two\twith tab"), a("quotes \" and emoji 🚀 and \\ backslash")]
        let restored = try store.decode(store.encode(tricky))
        XCTAssertEqual(restored.map(\.text), tricky.map(\.text))
    }

    func testRestoreSeedsChatModelFromSavedTranscript() {
        let chat = ChatModel(engine: MockInferenceEngine())
        let saved = try! store.decode(store.encode([u("earlier question"), a("earlier answer")]))
        chat.restore(saved)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.first?.text, "earlier question")
        XCTAssertEqual(chat.messages.last?.role, .assistant)
    }
}
