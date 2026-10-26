import XCTest
import Combine
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

    /// Yields the scripted pieces once, then parks until `openGate()`; later calls answer directly.
    private actor StopEngine: InferenceEngine {
        private let firstPieces: [String]
        private let laterReply: String
        private var loaded: String? = "stop-engine"
        private(set) var calls = 0
        private(set) var cancellations = 0
        private var release: CheckedContinuation<Void, Never>?
        private var releaseReady = false

        init(firstPieces: [String], laterReply: String = "next reply") {
            self.firstPieces = firstPieces
            self.laterReply = laterReply
        }

        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
        func unload() async { loaded = nil }
        func requestCancel() { cancellations += 1 }

        func openGate() {
            if let release {
                self.release = nil
                release.resume()
            } else {
                releaseReady = true
            }
        }

        private func waitForGate() async {
            if releaseReady { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                release = continuation
            }
        }

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            guard loaded != nil else { throw InferenceError.modelNotLoaded }
            calls += 1
            let call = calls
            let pieces = firstPieces
            let reply = laterReply
            return AsyncThrowingStream { continuation in
                if call > 1 {
                    continuation.yield(reply)
                    continuation.finish()
                    return
                }
                for piece in pieces { continuation.yield(piece) }
                Task { [weak self] in
                    await self?.waitForGate()
                    continuation.finish()
                }
            }
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

    /// Wait for a specific last-message text without polling (bounded by XCTest's timeout).
    private func waitForMessage(_ chat: ChatModel, _ text: String) async {
        if chat.messages.last?.text == text { return }
        let landed = expectation(description: "message landed: \(text)")
        landed.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = chat.$messages.sink { messages in
            if messages.last?.text == text { landed.fulfill() }
        }
        await fulfillment(of: [landed], timeout: 5)
        cancellable?.cancel()
    }

    func testStopSettlesTheCollapsedPreStopWall() async {
        let wall = Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
        let engine = await loaded(StopEngine(firstPieces: [wall]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await waitForMessage(chat, wall)
        chat.stopGenerating()
        await engine.openGate()
        await task.value

        XCTAssertEqual(chat.messages.last?.text, paragraph)
        let cancellations = await engine.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testSendDuringSettlementIsANoOpAndAfterwardAppends() async {
        let engine = await loaded(StopEngine(firstPieces: ["partial"]))
        let chat = ChatModel(engine: engine)
        let task = Task { await chat.send("question") }

        await waitForMessage(chat, "partial")
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

        await waitForMessage(chat, "")
        chat.stopGenerating()
        await engine.openGate()
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

        await waitForMessage(chat, "partial")
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

        await waitForMessage(chat, wall)
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
}
