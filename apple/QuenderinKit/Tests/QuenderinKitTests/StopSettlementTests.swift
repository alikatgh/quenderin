import XCTest
import Combine
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

    /// Unlike the pull fixture, this exercises AsyncThrowingStream's own consumer-cancellation
    /// path: cancelling the task finishes next() with nil and reports .cancelled to the producer.
    /// All test waits are bounded, and synchronous finish lets defer release the stream on failure.
    private final class ContinuationEngine: InferenceEngine {
        private struct State {
            var loaded: String? = "continuation-engine"
            var calls = 0
            var secondHistory: [ChatMessage] = []
            var continuation: AsyncThrowingStream<String, Error>.Continuation?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        let started = XCTestExpectation(description: "continuation stream connected")
        let cancelled = XCTestExpectation(description: "stream terminated by consumer cancellation")

        var secondHistory: [ChatMessage] { state.withLock { $0.secondHistory } }
        func loadedModelID() async -> String? { state.withLock { $0.loaded } }
        func load(model: ModelEntry, at fileURL: URL) async throws { state.withLock { $0.loaded = model.id } }
        func unload() async { state.withLock { $0.loaded = nil } }
        func requestCancel() {} // Explicit Stop must still wait for the consumer task to unwind.

        func emit(_ text: String) {
            let continuation = state.withLock { $0.continuation }
            continuation?.yield(text)
        }

        func finish() {
            let continuation = state.withLock {
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }
            continuation?.finish()
        }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            try await generateChat(system: prompt, history: [], options: options)
        }

        func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            let subsequent = state.withLock {
                $0.calls += 1
                if $0.calls > 1 { $0.secondHistory = history }
                return $0.calls > 1
            }
            if subsequent {
                return AsyncThrowingStream { continuation in
                    continuation.yield("next reply")
                    continuation.finish()
                }
            }
            return AsyncThrowingStream { continuation in
                continuation.onTermination = { [cancelled] termination in
                    if case .cancelled = termination { cancelled.fulfill() }
                }
                state.withLock { $0.continuation = continuation }
                started.fulfill()
            }
        }
    }

    private func waitFor(_ expectations: [XCTestExpectation], file: StaticString = #filePath,
                         line: UInt = #line) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
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

    func testConsumerTaskCancellationDiscardsTheAcceptedPartial() async {
        let engine = ContinuationEngine()
        let chat = ChatModel(engine: engine)
        let accepted = XCTestExpectation(description: "partial accepted into the transcript")
        let finished = XCTestExpectation(description: "cancelled send settled")
        let subscription = chat.$messages.first { $0.last?.text == "partial" }.sink { _ in accepted.fulfill() }
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { task.cancel(); engine.finish(); subscription.cancel() }

        guard await waitFor([engine.started]) else { return }
        engine.emit("partial")
        guard await waitFor([accepted]) else { return }
        XCTAssertEqual(chat.messages.map(\.text), ["question", "partial"])
        let revision = chat.transcriptRevision
        task.cancel()
        guard await waitFor([engine.cancelled, finished]) else { return }

        XCTAssertEqual(chat.messages.map(\.text), ["question"])
        XCTAssertEqual(chat.completedMessages().map(\.text), ["question"])
        XCTAssertEqual(chat.transcriptRevision, revision + 1)
        XCTAssertFalse(chat.isGenerating)
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testConsumerTaskCancellationBeforeAnyTokenLeavesOnlyTheUser() async {
        let engine = ContinuationEngine()
        let chat = ChatModel(engine: engine)
        let finished = XCTestExpectation(description: "zero-token cancelled send settled")
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { task.cancel(); engine.finish() }

        guard await waitFor([engine.started]) else { return }
        XCTAssertEqual(chat.messages.map(\.text), ["question", ""])
        task.cancel()
        guard await waitFor([engine.cancelled, finished]) else { return }

        XCTAssertEqual(chat.messages.map(\.text), ["question"])
        XCTAssertEqual(chat.completedMessages().map(\.text), ["question"])
        XCTAssertFalse(chat.isGenerating)
    }

    func testConsumerTaskCancelledPartialCannotReachNextHistoryOrReopenedPersistence() async {
        let persistence = CountingPersistence()
        let engine = ContinuationEngine()
        let chat = ChatModel(engine: engine)
        let coord = ConversationCoordinator(chat: chat, persistence: persistence, now: { 8 })
        let id = coord.currentID!
        let accepted = XCTestExpectation(description: "partial accepted before task cancellation")
        let finished = XCTestExpectation(description: "cancelled send completed before next turn")
        let subscription = chat.$messages.first { $0.last?.text == "partial" }.sink { _ in accepted.fulfill() }
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { task.cancel(); engine.finish(); subscription.cancel() }

        guard await waitFor([engine.started]) else { return }
        engine.emit("partial")
        guard await waitFor([accepted]) else { return }
        task.cancel()
        guard await waitFor([engine.cancelled, finished]) else { return }

        coord.persist()
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question"])
        await chat.send("next")
        XCTAssertEqual(engine.secondHistory.map(\.text), ["question", "next"])
        coord.persist()
        coord.open(id)

        XCTAssertEqual(chat.messages.map(\.text), ["question", "next", "next reply"])
        XCTAssertEqual(persistence.loadTranscript(id: id).map(\.text), ["question", "next", "next reply"])
    }

    func testExplicitStopThenConsumerTaskCancellationRetainsCollapsedAcceptedText() async {
        let engine = ContinuationEngine()
        let chat = ChatModel(engine: engine)
        let wall = Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
        let accepted = XCTestExpectation(description: "repeated paragraphs accepted before Stop")
        let finished = XCTestExpectation(description: "stopped cancelled send settled")
        let subscription = chat.$messages.first { $0.last?.text == wall }.sink { _ in accepted.fulfill() }
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { task.cancel(); engine.finish(); subscription.cancel() }

        guard await waitFor([engine.started]) else { return }
        engine.emit(wall)
        guard await waitFor([accepted]) else { return }
        chat.stopGenerating()
        task.cancel()
        guard await waitFor([engine.cancelled, finished]) else { return }

        XCTAssertEqual(chat.messages.map(\.text), ["question", paragraph])
        XCTAssertEqual(chat.completedMessages().map(\.text), ["question", paragraph])
        XCTAssertFalse(chat.lastHitTokenCap)
        XCTAssertFalse(chat.isGenerating)
    }

    func testStaleConsumerTaskCancellationCannotChangeRestoredMessages() async {
        let engine = ContinuationEngine()
        let chat = ChatModel(engine: engine)
        let accepted = XCTestExpectation(description: "partial accepted before navigation")
        let finished = XCTestExpectation(description: "stale cancelled send returned")
        let subscription = chat.$messages.first { $0.last?.text == "partial" }.sink { _ in accepted.fulfill() }
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { task.cancel(); engine.finish(); subscription.cancel() }

        guard await waitFor([engine.started]) else { return }
        engine.emit("partial")
        guard await waitFor([accepted]) else { return }
        // Reopening a saved transcript can restore the same message ID with different text.
        let restored = ChatMessage(id: chat.messages.last!.id, role: .assistant, text: "saved answer")
        chat.restore([restored])
        let revision = chat.transcriptRevision
        task.cancel()
        guard await waitFor([engine.cancelled, finished]) else { return }

        XCTAssertEqual(chat.messages, [restored])
        XCTAssertEqual(chat.completedMessages(), [restored])
        XCTAssertEqual(chat.transcriptRevision, revision)
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
