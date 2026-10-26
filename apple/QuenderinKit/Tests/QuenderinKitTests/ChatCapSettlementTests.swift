import XCTest
import os
@testable import QuenderinKit

/// Only the engine's observed budget stop offers Continue; a streamed piece count is not a reason.
@MainActor
final class ChatCapSettlementTests: XCTestCase {
    private struct Outcome: Sendable {
        let pieces: [String]
        let status: ChatCapStatus
    }

    private final class StatusEngine: InferenceEngine {
        private struct State {
            var calls = 0
            var lastHistory: [ChatMessage] = []
            var releaseReady = false
            var pendingStatus: (CheckedContinuation<ChatCapStatus, Never>, ChatCapStatus)?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let outcomes: [Outcome]
        private let gateFirstStatus: Bool
        let statusEntered = XCTestExpectation(description: "cap status suspended")

        init(_ outcomes: [Outcome], gateFirstStatus: Bool = false) {
            self.outcomes = outcomes
            self.gateFirstStatus = gateFirstStatus
        }

        var lastHistory: [ChatMessage] { state.withLock { $0.lastHistory } }
        func loadedModelID() async -> String? { "cap-settlement" }
        func load(model: ModelEntry, at fileURL: URL) async throws {}
        func unload() async {}
        func requestCancel() {} // Deliberately retain the in-progress status result after Stop.

        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            try await generateChat(system: prompt, history: [], options: options)
        }

        func generateChat(system: String, history: [ChatMessage], options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            let outcome = state.withLock {
                let outcome = outcomes[$0.calls]
                $0.calls += 1
                $0.lastHistory = history
                return outcome
            }
            return AsyncThrowingStream { continuation in
                for piece in outcome.pieces { continuation.yield(piece) }
                continuation.finish()
            }
        }

        func chatCapStatus() async -> ChatCapStatus {
            await withCheckedContinuation { continuation in
                let immediate: ChatCapStatus? = state.withLock {
                    let status = outcomes[$0.calls - 1].status
                    if gateFirstStatus, $0.calls == 1, !$0.releaseReady {
                        $0.pendingStatus = (continuation, status)
                        return nil
                    }
                    return status
                }
                if let immediate { continuation.resume(returning: immediate) }
                else { statusEntered.fulfill() }
            }
        }

        func openStatusGate() {
            let pending = state.withLock {
                $0.releaseReady = true
                let pending = $0.pendingStatus
                $0.pendingStatus = nil
                return pending
            }
            if let (continuation, status) = pending { continuation.resume(returning: status) }
        }
    }

    private func waitFor(_ expectation: XCTestExpectation, file: StaticString = #filePath,
                         line: UInt = #line) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
    }

    /// The expectation proves execution is inside chatCapStatus, with bounded failure cleanup.
    private func settleBlocked(_ engine: StatusEngine, chat: ChatModel,
                               action: (Task<Void, Never>) -> Void) async -> Bool {
        let finished = XCTestExpectation(description: "send settled after status release")
        let task = Task { await chat.send("question"); finished.fulfill() }
        defer { engine.openStatusGate(); task.cancel() }
        guard await waitFor(engine.statusEntered) else { return false }
        action(task)
        engine.openStatusGate()
        return await waitFor(finished)
    }

    func testHitWithZeroOrFewPiecesOffersContinueAndKeepsEmptyReplyNotice() async {
        for pieces in [[], ["short answer"]] {
            let chat = ChatModel(engine: StatusEngine([Outcome(pieces: pieces, status: .hit)]))
            await chat.send("question", options: .init(maxTokens: 128))
            XCTAssertEqual(chat.messages.last?.text, pieces.first ?? ChatUserFacing.emptyReply())
            XCTAssertTrue(chat.lastHitTokenCap)
        }
    }

    func testManyPiecesNeverSubstituteForNotHitOrUnknown() async {
        let pieces = ["one ", "two ", "three ", "four"]
        for status in [ChatCapStatus.notHit, .unknown] {
            let chat = ChatModel(engine: StatusEngine([Outcome(pieces: pieces, status: status)]))
            await chat.send("question", options: .init(maxTokens: 2))
            XCTAssertEqual(chat.messages.last?.text, pieces.joined())
            XCTAssertFalse(chat.lastHitTokenCap)
        }
    }

    func testSuccessiveStatusesReplaceThePreviousOutcome() async {
        let statuses: [ChatCapStatus] = [.hit, .unknown, .hit, .notHit]
        let chat = ChatModel(engine: StatusEngine(statuses.map { Outcome(pieces: ["answer"], status: $0) }))
        for status in statuses {
            await chat.send("question")
            XCTAssertEqual(chat.lastHitTokenCap, status == .hit)
        }
    }

    func testStopDuringStatusRetainsAcceptedTextAndSuppressesHit() async {
        for pieces in [[], ["accepted"]] {
            let engine = StatusEngine([Outcome(pieces: pieces, status: .hit)], gateFirstStatus: true)
            let chat = ChatModel(engine: engine)
            guard await settleBlocked(engine, chat: chat, action: { _ in chat.stopGenerating() }) else { return }
            XCTAssertEqual(chat.messages.map(\.text), ["question", pieces.joined()])
            XCTAssertEqual(chat.messages, chat.completedMessages())
            XCTAssertEqual(chat.messages, chat.persistSnapshot().0)
            XCTAssertFalse(chat.lastHitTokenCap)
            XCTAssertFalse(chat.isGenerating)
        }
    }

    func testStopThenTaskCancellationDuringStatusStillRetainsAcceptedText() async {
        let engine = StatusEngine([Outcome(pieces: ["accepted"], status: .hit)], gateFirstStatus: true)
        let chat = ChatModel(engine: engine)
        guard await settleBlocked(engine, chat: chat, action: { task in
            chat.stopGenerating()
            task.cancel()
        }) else { return }
        XCTAssertEqual(chat.messages.map(\.text), ["question", "accepted"])
        XCTAssertEqual(chat.messages, chat.persistSnapshot().0)
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testNavigationDuringStatusCannotOverwriteRestoredSameID() async {
        let engine = StatusEngine([Outcome(pieces: ["partial"], status: .hit)], gateFirstStatus: true)
        let chat = ChatModel(engine: engine)
        var restored: [ChatMessage] = []
        var revision: UInt64 = 0
        guard await settleBlocked(engine, chat: chat, action: { _ in
            restored = [ChatMessage(id: chat.messages.last!.id, role: .assistant, text: "saved answer")]
            chat.restore(restored)
            revision = chat.transcriptRevision
        }) else { return }
        XCTAssertEqual(chat.messages, restored)
        XCTAssertEqual(chat.completedMessages(), restored)
        XCTAssertEqual(chat.transcriptRevision, revision)
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testAbandonedStatusCannotOfferContinueOrLeakIntoTheNextTurn() async {
        for fresh in [ChatCapStatus.notHit, .hit] {
            let engine = StatusEngine([
                Outcome(pieces: ["old"], status: .hit),
                Outcome(pieces: ["new"], status: fresh),
            ], gateFirstStatus: true)
            let chat = ChatModel(engine: engine)
            guard await settleBlocked(engine, chat: chat, action: { _ in chat.reset() }) else { return }
            XCTAssertTrue(chat.messages.isEmpty)
            XCTAssertFalse(chat.lastHitTokenCap)
            await chat.send("next")
            XCTAssertEqual(chat.messages.map(\.text), ["next", "new"])
            XCTAssertFalse(engine.lastHistory.contains { $0.text == "old" })
            XCTAssertEqual(chat.lastHitTokenCap, fresh == .hit)
        }
    }

    func testExternalCancellationDuringStatusDiscardsThePartialBeforePersistenceAndNextHistory() async {
        let engine = StatusEngine([
            Outcome(pieces: ["partial"], status: .hit),
            Outcome(pieces: ["new"], status: .unknown),
        ], gateFirstStatus: true)
        let chat = ChatModel(engine: engine)
        guard await settleBlocked(engine, chat: chat, action: { $0.cancel() }) else { return }
        XCTAssertEqual(chat.messages.map(\.text), ["question"])
        XCTAssertEqual(chat.messages, chat.persistSnapshot().0)
        XCTAssertFalse(chat.lastHitTokenCap)
        await chat.send("next")
        XCTAssertFalse(engine.lastHistory.contains { $0.text == "partial" })
        XCTAssertFalse(chat.lastHitTokenCap)
    }

    func testDegenerationSuppressesAnObservedHit() async {
        let pieces = Array(repeating: "abcdefghijklmnop", count: 40)
        let chat = ChatModel(engine: StatusEngine([Outcome(pieces: pieces, status: .hit)]))
        await chat.send("question")
        XCTAssertEqual(chat.messages.last?.text, pieces.prefix(31).joined())
        XCTAssertFalse(chat.lastHitTokenCap)
    }
}
