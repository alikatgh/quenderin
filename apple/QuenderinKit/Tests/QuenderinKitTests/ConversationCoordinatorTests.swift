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
    func testDeleteManyFallsBackOnceAndClearsPrefs() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("r")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })
        await chat.send("one"); coord.persist()
        coord.startNew(); await chat.send("two"); coord.persist()
        coord.startNew(); await chat.send("three"); coord.persist()
        XCTAssertEqual(coord.summaries.count, 3)

        let ids = coord.summaries.map(\.id)          // newest first: "three", "two", "one"
        ChatPrefsStore.shared.set(fontStyle: "serif", fontSize: nil, for: ids[0])
        coord.deleteMany([ids[0], ids[1]])            // includes the CURRENT conversation

        XCTAssertEqual(coord.summaries.map(\.title), ["one"])
        XCTAssertEqual(coord.currentID, ids[2], "fallback restores the surviving conversation")
        XCTAssertEqual(chat.messages.first?.text, "one")
        XCTAssertNil(ChatPrefsStore.shared.fontStyle(for: ids[0]), "per-chat prefs die with the chat")
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

    /// `persist()` mid-stream must not write the trailing placeholder/partial assistant message to
    /// disk. Pre-fix, `open()`/`startNew()` navigating away while a reply is in flight saved a
    /// transcript ending in an empty assistant turn (see `ChatModelTests` for the matching
    /// `isGenerating` spin-wait pattern this borrows).
    @MainActor
    func testPersistIsNoOpWhileGenerating() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("one two three four five")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })

        let id = coord.currentID!   // the fresh conversation; no history row exists until a save

        let task = Task { await chat.send("hello") }
        while chat.messages.count < 2 { await Task.yield() }   // user+placeholder assistant appended
        XCTAssertTrue(chat.isGenerating)

        coord.open("does-not-exist")   // persist() runs first internally; must not save mid-stream
        XCTAssertTrue(coord.summaries.isEmpty)                    // "hello" never landed — still no row
        XCTAssertTrue(persistence.loadTranscript(id: id).isEmpty) // and nothing was written to disk

        await task.value   // let the stream finish so the task doesn't leak past the test
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
        // Back to first-launch state: the chat is empty and the history is empty too — the fresh
        // conversation only earns a row once something is said.
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNotNil(coord.currentID)   // there IS a fresh conversation to type into
        XCTAssertTrue(coord.summaries.isEmpty)
        XCTAssertTrue(persistence.loadIndex().isEmpty)   // persistence actually wiped
    }

    /// The WhatsApp rule end-to-end: launching fresh (or pressing New Chat) shows NO history row;
    /// the row appears only when the first completed turn is persisted.
    @MainActor
    func testFirstLaunchCreatesNoRowUntilFirstTurnIsSaved() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("hello")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 7 })
        XCTAssertTrue(coord.summaries.isEmpty)
        XCTAssertTrue(persistence.loadIndex().isEmpty)
        XCTAssertNotNil(coord.currentID)   // but there IS a current conversation to type into

        await chat.send("first message")
        coord.persist()
        XCTAssertEqual(coord.summaries.map(\.title), ["first message"])
    }

    /// Migration for installs that ran the old create-immediately `startNew()`: blank
    /// "New conversation" shells are garbage-collected on init, and launch restores the newest
    /// REAL conversation instead of an empty shell.
    @MainActor
    func testInitPrunesLegacyBlankConversationRows() async {
        let persistence = InMemoryConversationPersistence()
        persistence.saveTranscript(id: "real", messages: [ChatMessage(role: .user, text: "keep me")])
        persistence.saveTranscript(id: "blank1", messages: [])
        persistence.saveIndex([
            ConversationSummary(id: "real", title: "keep me", updatedAt: 1),
            ConversationSummary(id: "blank1", title: "New conversation", updatedAt: 2),
            ConversationSummary(id: "blank2", title: "New conversation", updatedAt: 3),
        ])
        let coord = ConversationCoordinator(chat: await loadedChat("x"), persistence: persistence, now: { 9 })
        XCTAssertEqual(coord.summaries.map(\.id), ["real"])   // shells GC'd everywhere
        XCTAssertEqual(persistence.loadIndex().map(\.id), ["real"])
        XCTAssertEqual(coord.currentID, "real")               // restored the real chat, not a shell
        XCTAssertEqual(coord.chat.messages.map(\.text), ["keep me"])
    }
}
