import XCTest
@testable import QuenderinKit

final class ConversationCoordinatorTests: XCTestCase {

    // MARK: - FileConversationPersistence (the on-disk edge)

    func testFilePersistenceRoundTripsTranscriptAndIndex() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conv-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileConversationPersistence(directory: dir)

        store.saveTranscript(id: "abc", messages: [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "hello"),
        ])
        XCTAssertEqual(store.loadTranscript(id: "abc").map(\.text), ["hi", "hello"])
        XCTAssertEqual(store.loadTranscript(id: "abc").map(\.role), [.user, .assistant])

        store.saveIndex([ConversationSummary(id: "abc", title: "hi", updatedAt: 123)])
        XCTAssertEqual(store.loadIndex().map(\.id), ["abc"])
        XCTAssertEqual(store.loadIndex().first?.title, "hi")

        store.deleteTranscript(id: "abc")
        XCTAssertTrue(store.loadTranscript(id: "abc").isEmpty)   // missing == empty, not an error
    }

    func testFilePersistenceMissingFilesAreEmptyNotErrors() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conv-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileConversationPersistence(directory: dir)
        XCTAssertTrue(store.loadIndex().isEmpty)
        XCTAssertTrue(store.loadTranscript(id: "nope").isEmpty)
    }

    // MARK: - ConversationCoordinator (lifecycle bound to a live ChatModel)

    @MainActor
    private func loadedChat(_ reply: String) async -> ChatModel {
        let engine = MockInferenceEngine(cannedReply: reply)
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        return ChatModel(engine: engine)
    }

    @MainActor
    func testRestoresMostRecentConversationAcrossSessions() async {
        let persistence = InMemoryConversationPersistence()
        let chat1 = await loadedChat("hello there")
        let session1 = ConversationCoordinator(chat: chat1, persistence: persistence, now: { 1000 })
        await chat1.send("first question")
        session1.persist()

        // A fresh session over the SAME persistence picks up where it left off.
        let chat2 = await loadedChat("ignored")
        let session2 = ConversationCoordinator(chat: chat2, persistence: persistence, now: { 2000 })
        XCTAssertEqual(chat2.messages.map(\.text), ["first question", "hello there"])
        XCTAssertEqual(session2.summaries.count, 1)
        XCTAssertEqual(session2.summaries.first?.title, "first question")   // titled from first user line
    }

    @MainActor
    func testStartNewIsNoOpOnAnEmptyChat() async {
        let persistence = InMemoryConversationPersistence()
        let coord = ConversationCoordinator(chat: await loadedChat("x"), persistence: persistence, now: { 1 })
        let before = coord.summaries.count
        coord.startNew()   // nothing typed yet → don't stack blank conversations
        XCTAssertEqual(coord.summaries.count, before)
    }

    @MainActor
    func testDeletingTheCurrentConversationStartsFresh() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("ok")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 5 })
        await chat.send("keep me")
        coord.persist()
        let id = coord.summaries.first!.id

        coord.delete(id)
        XCTAssertFalse(coord.summaries.contains { $0.id == id })
        XCTAssertTrue(chat.messages.isEmpty)   // fell back to a fresh, empty conversation
    }

    @MainActor
    func testNewConversationThenReopenPriorOne() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("reply")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 10 })

        await chat.send("conversation A")
        coord.persist()
        let idA = coord.summaries.first!.id

        coord.startNew()
        await chat.send("conversation B")
        coord.persist()
        XCTAssertEqual(coord.summaries.count, 2)

        coord.open(idA)   // switch back
        XCTAssertEqual(chat.messages.first?.text, "conversation A")
    }

    @MainActor
    func testClearAllWipesHistoryThenStartsFresh() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("ok")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })
        await chat.send("one")
        coord.persist()
        coord.startNew()
        await chat.send("two")
        coord.persist()
        XCTAssertEqual(coord.summaries.count, 2)

        coord.clearAll()
        // Back to first-launch state: the chat is empty and only a fresh conversation remains.
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(coord.summaries.count, 1)
        XCTAssertEqual(coord.summaries.first?.title, "New conversation")
        XCTAssertEqual(persistence.loadIndex().count, 1)   // persistence actually wiped
    }
}
