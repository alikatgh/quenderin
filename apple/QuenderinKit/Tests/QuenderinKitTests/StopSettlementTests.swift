import XCTest
import os
@testable import QuenderinKit

/// Explicit Stop retains transcript ownership until the send settles the text accepted BEFORE the
/// Stop exactly once. A concurrent Send is a no-op; navigation abandons the partial and prevents the
/// late write; persistence uses an atomic completed/revision snapshot.
///
/// Source-only in this environment (no Apple build); hosted Swift verification is pending.
@MainActor
final class StopSettlementTests: XCTestCase {

    private let paragraph =
        "Quender was a forest elf, a member of the slender and agile forest elves of the deep wood."

    /// Pull-based stream: parking proves ChatModel consumed every pre-Stop piece, including its
    /// unflushed tail. A gate can then deliver one deliberately late piece without using sleeps.
    private actor StopEngine: InferenceEngine {
        private let firstPieces: [String]
        private let laterReply: String
        private var loaded: String? = "stop-engine"
        private(set) var calls = 0
        private(set) var secondHistory: [ChatMessage] = []
        // Same synchronous lock pattern as CancelTrackingEngine: protocol cancellation cannot hop actors.
        private nonisolated let cancelState = OSAllocatedUnfairLock(initialState: 0)
        nonisolated var cancellations: Int { cancelState.withLock { $0 } }
        private var nextIndex = 0
        private var parked = false
        private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        private var releaseReady = false
        private var latePiece: String?
        private var errorAfterGate: Error?

        init(firstPieces: [String], laterReply: String = "next reply") {
            self.firstPieces = firstPieces
            self.laterReply = laterReply
        }

        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
        func unload() async { loaded = nil }
        nonisolated func requestCancel() { cancelState.withLock { $0 += 1 } }

        func waitUntilParked() async {
            if parked { return }
            await withCheckedContinuation { parkedWaiters.append($0) }
        }

        func openGate(latePiece: String? = nil, error: Error? = nil) {
            self.latePiece = latePiece
            self.errorAfterGate = error
            releaseReady = true
            release?.resume()
            release = nil
        }

        private func nextPiece() async throws -> String? {
            if nextIndex < firstPieces.count {
                defer { nextIndex += 1 }
                return firstPieces[nextIndex]
            }
            parked = true
            let waiters = parkedWaiters
            parkedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !releaseReady {
                await withCheckedContinuation { release = $0 }
            }
            defer { latePiece = nil; errorAfterGate = nil }
            if let errorAfterGate { throw errorAfterGate }
            return latePiece
        }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            guard loaded != nil else { throw InferenceError.modelNotLoaded }
            calls += 1
            if calls > 1 {
                let reply = laterReply
                return AsyncThrowingStream { continuation in
                    continuation.yield(reply)
                    continuation.finish()
                }
            }
            return AsyncThrowingStream(unfolding: { [weak self] in
                try await self?.nextPiece()
            })
        }

        func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            if calls >= 1 { secondHistory = history }
            return try await generate(prompt: system, options: options)
        }
    }

    private final class CountingPersistence: ConversationPersistence {
        private let store = InMemoryConversationPersistence()
        private(set) var writes = 0
        func saveTranscript(id: String, messages: [ChatMessage]) {
            writes += 1
            store.saveTranscript(id: id, messages: messages)
        }
        func loadTranscript(id: String) -> [ChatMessage] { store.loadTranscript(id: id) }
        func deleteTranscript(id: String) { store.deleteTranscript(id: id) }
        func saveIndex(_ summaries: [ConversationSummary]) { store.saveIndex(summaries) }
        func loadIndex() -> [ConversationSummary] { store.loadIndex() }
    }

    private func loaded(_ engine: StopEngine) async -> StopEngine {
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        return engine
    }

    func testStopSettlesTheCollapsedPreStopWall() async {
        let wall = Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
        let engine = await loaded(StopEngine(firstPieces: [wall]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        await engine.openGate()
        await task.value

        XCTAssertEqual(chat.messages.last?.text, paragraph)
        let cancellations = engine.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testSendDuringSettlementIsANoOpAndAfterwardAppends() async {
        let engine = await loaded(StopEngine(firstPieces: ["partial"]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        await chat.send("next")                 // no-op while the stopped turn settles
        let duringCalls = await engine.calls
        XCTAssertEqual(duringCalls, 1)
        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])

        await engine.openGate()
        await task.value
        await chat.send("next")                 // settlement finished → appends normally
        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial", "next", "next reply"])
    }

    func testZeroTokenStopLeavesTheSameEmptyBubbleWithoutANotice() async {
        let engine = await loaded(StopEngine(firstPieces: []))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        await engine.openGate(latePiece: "late engine value")
        await task.value

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.text, "")
    }

    func testStopThenNewChatAbandonsThePartialAndTheLateSettleWritesNothing() async {
        let persistence = InMemoryConversationPersistence()
        let engine = await loaded(StopEngine(firstPieces: ["partial"]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 1 })
        let id = coord.currentID!
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        coord.startNew()
        await engine.openGate()
        await task.value

        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testPersistDuringSettlementGetsOneCorrectiveSave() async {
        let persistence = CountingPersistence()
        let wall = Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
        let engine = await loaded(StopEngine(firstPieces: [wall]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 2 })
        let id = coord.currentID!
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        coord.persist()
        let during = persistence.loadTranscript(id: id).map(\.text)
        XCTAssertEqual(during, ["question", wall])

        await engine.openGate()
        await task.value
        coord.persist()                          // corrective: same count, changed text
        coord.open(id)

        XCTAssertEqual(persistence.writes, 2)
        XCTAssertEqual(chat.messages.map(\.text), ["question", paragraph])
    }

    func testStopRetainsEveryBufferedPreStopPieceAndDropsTheLatePiece() async {
        let engine = await loaded(StopEngine(firstPieces: ["part", "ial"]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked() // The next pull proves both pieces were accepted before Stop.
        chat.stopGenerating()
        chat.stopGenerating()
        XCTAssertEqual(engine.cancellations, 1)
        await engine.openGate(latePiece: " late token")
        await task.value

        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])
        XCTAssertEqual(engine.cancellations, 1)
        XCTAssertFalse(chat.isGenerating)
    }

    func testStopThenInterimPersistThenNewDurablyRemovesThePartial() async {
        let persistence = CountingPersistence()
        let engine = await loaded(StopEngine(firstPieces: ["partial"]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 3 })
        let id = coord.currentID!
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        coord.persist()
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question", "partial"])
        coord.startNew()
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])
        await engine.openGate(latePiece: " late token")
        await task.value
        coord.persist()

        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(persistence.writes, 2)
        coord.open(id)
        XCTAssertEqual(chat.messages.map(\.text), ["question"])
    }

    /// Access through the protocol proves cancellation is synchronous/nonisolated. The gate also
    /// proves the fixture has not completed generation when cancellation is recorded.
    func testFixtureCancellationMatchesTheSynchronousProtocolRequirement() async {
        let engine = await loaded(StopEngine(firstPieces: []))
        let contract: any InferenceEngine = engine
        contract.requestCancel()
        XCTAssertEqual(engine.cancellations, 1)
        let loadedID = await contract.loadedModelID()
        XCTAssertNotNil(loadedID)
    }

    func testStopPreservesAcceptedTextWhenCompletionThrows() async {
        let engine = await loaded(StopEngine(firstPieces: ["part", "ial"]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()   // proves both pieces were consumed before Stop
        chat.stopGenerating()
        await engine.openGate(error: InferenceError.generationFailed(reason: "engine cancelled"))
        await task.value

        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])
        XCTAssertEqual(engine.cancellations, 1)
        XCTAssertFalse(chat.lastHitTokenCap)
        XCTAssertFalse(chat.isGenerating)
    }

    func testZeroTokenStopThenCompletionErrorStaysEmpty() async {
        let engine = await loaded(StopEngine(firstPieces: []))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        await engine.openGate(error: InferenceError.generationFailed(reason: "engine cancelled"))
        await task.value

        XCTAssertEqual(chat.messages.map(\.text), ["question", ""])
    }

    func testUnstoppedGenuineErrorKeepsTheWarning() async {
        let engine = await loaded(StopEngine(firstPieces: ["part"]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        await engine.openGate(error: InferenceError.generationFailed(reason: "genuine failure"))
        await task.value

        let text = chat.messages.last?.text ?? ""
        XCTAssertTrue(text.hasPrefix("⚠️"), "unstopped errors keep the existing warning")
        XCTAssertFalse(chat.isGenerating)
    }

    func testExternalCancellationDiscardsThePartialBeforeTheNextTurn() async {
        let persistence = CountingPersistence()
        let engine = await loaded(StopEngine(firstPieces: ["part"]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 7 })
        let id = coord.currentID!
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        await engine.openGate(error: CancellationError())
        await task.value

        XCTAssertEqual(chat.messages.map(\.text), ["question"])
        XCTAssertEqual(chat.completedMessages().map(\.text), ["question"])

        await chat.send("next")
        let history = await engine.secondHistory
        XCTAssertEqual(history.map(\.text), ["question", "next"])
        coord.persist()
        coord.open(id)

        XCTAssertEqual(chat.messages.map(\.text), ["question", "next", "next reply"])
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question", "next", "next reply"])
    }

    func testStaleErrorAfterNavigationCannotTouchTheNewChat() async {
        let persistence = CountingPersistence()
        let engine = await loaded(StopEngine(firstPieces: ["A-part"]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 4 })
        let oldID = coord.currentID!
        let task = Task { await chat.send("A") }

        await engine.waitUntilParked()
        coord.startNew()
        await engine.openGate(error: InferenceError.generationFailed(reason: "stale A"))
        await task.value

        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(persistence.loadTranscript(id: oldID).map(\.text), ["A"])
    }

    func testStoppedErrorPersistsAndReopensExactlyOnce() async {
        let persistence = CountingPersistence()
        let engine = await loaded(StopEngine(firstPieces: ["part", "ial"]))
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 6 })
        let id = coord.currentID!
        let task = Task { await chat.send("question") }

        await engine.waitUntilParked()
        chat.stopGenerating()
        await engine.openGate(error: InferenceError.generationFailed(reason: "engine cancelled"))
        await task.value
        coord.persist()
        coord.open(id)

        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question", "partial"])
        XCTAssertEqual(persistence.writes, 1)
    }

}
