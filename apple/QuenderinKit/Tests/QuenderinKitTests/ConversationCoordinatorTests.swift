import XCTest
@testable import QuenderinKit

/// Streams exactly what the test yields, so a navigation/Stop can be exercised while the assistant
/// turn is genuinely in flight — no timers, no scheduling assumptions. Mirrors the proven
/// `SelectionFixtureEngine.openAgentStream` continuation pattern.
private actor ControlledStreamEngine: InferenceEngine {
    private var loaded: String? = "controlled-stream"
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var started = false

    func loadedModelID() async -> String? { loaded }
    func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
    func unload() async { loaded = nil }

    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        guard loaded != nil else { throw InferenceError.modelNotLoaded }
        return AsyncThrowingStream { continuation = $0; started = true }
    }

    func isStarted() -> Bool { started }
    func emit(_ text: String) { continuation?.yield(text) }
    func finish() { continuation?.finish(); continuation = nil }
}

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

    /// A chat whose reply the test drives token by token (see `ControlledStreamEngine`).
    private func streamingChat() async -> (ChatModel, ControlledStreamEngine) {
        let engine = ControlledStreamEngine()
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        return (ChatModel(engine: engine), engine)
    }

    /// Wait until `send` has connected the engine stream, so `emit` cannot be dropped.
    private func waitUntilStreaming(_ engine: ControlledStreamEngine) async {
        while true {
            if await engine.isStarted() { return }
            await Task.yield()
        }
    }

    /// Wait until the first piece has landed in the transcript (the first piece always flushes).
    @MainActor
    private func waitForReplyText(_ chat: ChatModel, _ text: String) async {
        while chat.messages.last?.text != text { await Task.yield() }
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
        // An ADVANCING clock: with a constant clock every summary ties on updatedAt and the
        // newest-first ordering falls to random UUID tie-breaking (this test flaked on that).
        var clock: Int64 = 0
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { clock })
        await chat.send("one"); clock = 1; coord.persist()
        coord.startNew(); await chat.send("two"); clock = 2; coord.persist()
        coord.startNew(); await chat.send("three"); clock = 3; coord.persist()
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
    /// disk. The unsettled turn is abandoned (removed) before the save, so it also cannot reappear
    /// when the stream later settles. See `ChatModelTests` for the matching `isGenerating` spin-wait
    /// pattern this borrows.
    @MainActor
    func testPersistSavesUserTurnAndTrimsPartialAssistantWhileGenerating() async {
        let persistence = InMemoryConversationPersistence()
        let chat = await loadedChat("one two three four five")
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })

        let id = coord.currentID!   // the fresh conversation; no history row exists until a save

        let task = Task { await chat.send("hello") }
        while chat.messages.count < 2 { await Task.yield() }   // user+placeholder assistant appended
        XCTAssertTrue(chat.isGenerating)

        coord.open("does-not-exist")   // persist() runs first internally: must save the user's turn,
        // trimming the still-streaming (empty/partial) assistant placeholder rather than losing the
        // whole exchange to the isGenerating no-op.
        XCTAssertEqual(coord.summaries.count, 1)
        let saved = persistence.loadTranscript(id: id)
        XCTAssertEqual(saved.map(\.role), [.user])
        XCTAssertEqual(saved.map(\.text), ["hello"])

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

    /// Reviewer regression: Back mid-stream must abandon the partial, so the same stream completing
    /// afterwards can never be persisted by the next persist/reopen.
    @MainActor
    func testBackThenCompletionThenReopenDoesNotPersistPartial() async {
        let persistence = InMemoryConversationPersistence()
        let (chat, engine) = await streamingChat()
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })
        let id = coord.currentID!

        let task = Task { await chat.send("question") }
        while chat.messages.count < 2 { await Task.yield() }   // user + assistant placeholder
        await waitUntilStreaming(engine)
        await engine.emit("partial")
        await waitForReplyText(chat, "partial")
        XCTAssertTrue(chat.isGenerating)

        coord.persist()   // Back to the list, mid-stream (the actual caller)
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])

        await engine.finish()   // the abandoned stream still completes on the engine
        await task.value
        coord.persist()         // the isGenerating-fall persist after the stream ends
        coord.open(id)          // reopen the saved conversation
        XCTAssertEqual(chat.messages.map(\.text), ["question"])
    }

    /// New chat mid-stream is abandonment, not Stop: only the user's turn is saved and the fresh
    /// conversation is empty.
    @MainActor
    func testStartNewMidStreamSavesUserTurnOnly() async {
        let persistence = InMemoryConversationPersistence()
        let (chat, engine) = await streamingChat()
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 2 })
        let id = coord.currentID!

        let task = Task { await chat.send("question") }
        while chat.messages.count < 2 { await Task.yield() }
        await waitUntilStreaming(engine)
        await engine.emit("partial")
        await waitForReplyText(chat, "partial")

        coord.startNew()   // actual New-chat path: abandon, persist, reset
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])
        XCTAssertTrue(chat.messages.isEmpty)

        await engine.finish()
        await task.value
        coord.persist()    // repeat persist after the abandoned stream settles
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])
    }

    /// An explicit Stop is the opposite decision: the streamed partial IS the user's answer, so it
    /// must survive persist and reopen exactly once (reviewer: never delete valid Stop partials).
    @MainActor
    func testExplicitStopPartialSurvivesPersistAndReopen() async {
        let persistence = InMemoryConversationPersistence()
        let (chat, engine) = await streamingChat()
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 3 })
        let id = coord.currentID!

        let task = Task { await chat.send("question") }
        while chat.messages.count < 2 { await Task.yield() }
        await waitUntilStreaming(engine)
        await engine.emit("partial")
        await waitForReplyText(chat, "partial")

        chat.stopGenerating()   // ChatView's Stop button
        coord.persist()
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question", "partial"])

        await engine.finish()
        await task.value
        coord.persist()         // repeat persist must not drop or duplicate it
        coord.open(id)
        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])
    }
}
