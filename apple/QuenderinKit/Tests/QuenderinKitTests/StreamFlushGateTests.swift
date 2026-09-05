import XCTest
import Combine
@testable import QuenderinKit

/// End-to-end twin of the CoreVerify streaming-burst check: a 200-piece reply arriving inside one
/// display frame must not cause 200 transcript writes, while the first piece and the settle land.
@MainActor
final class ChatModelStreamPacingTests: XCTestCase {
    func testBurstOfPiecesInOneFrameDoesNotWritePerToken() async {
        let words = (0..<200).map { "t\($0)" }
        let engine = MockInferenceEngine(cannedReply: words.joined(separator: " "))   // mock streams per word
        try? await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        let chat = ChatModel(engine: engine)
        var assistantWrites = 0
        var firstStreamed: String?
        let sink = chat.$messages.sink { snap in
            guard snap.count == 2, !snap[1].text.isEmpty else { return }
            assistantWrites += 1
            if firstStreamed == nil { firstStreamed = snap[1].text }
        }
        await chat.send("go")
        sink.cancel()
        XCTAssertEqual(firstStreamed, "t0", "the first streamed piece must land immediately")
        XCTAssertLessThan(assistantWrites, 20, "200 pieces inside one frame must coalesce (got \(assistantWrites))")
        XCTAssertEqual(chat.messages[1].text, words.joined(separator: " "), "the settle writes the full reply")
    }
}

/// The transcript-write pacing for streaming replies (docs/INFERENCE_SLO.md, "Smoothness").
/// Twin of the CoreVerify `StreamFlushGate` checks — keep the vectors identical.
final class StreamFlushGateTests: XCTestCase {

    func testFirstPieceAlwaysFlushes() {
        var gate = StreamFlushGate(interval: .milliseconds(33))
        let t0 = ContinuousClock.Instant.now
        XCTAssertTrue(gate.shouldFlush(now: t0), "the bubble must show text the instant the model speaks")
    }

    func testWithinTheWindowIsHeldBack() {
        var gate = StreamFlushGate(interval: .milliseconds(33))
        let t0 = ContinuousClock.Instant.now
        _ = gate.shouldFlush(now: t0)
        XCTAssertFalse(gate.shouldFlush(now: t0 + .milliseconds(1)))
        XCTAssertFalse(gate.shouldFlush(now: t0 + .milliseconds(32)))
    }

    func testAfterTheWindowFlushesAndRearms() {
        var gate = StreamFlushGate(interval: .milliseconds(33))
        let t0 = ContinuousClock.Instant.now
        _ = gate.shouldFlush(now: t0)
        XCTAssertTrue(gate.shouldFlush(now: t0 + .milliseconds(33)))
        XCTAssertFalse(gate.shouldFlush(now: t0 + .milliseconds(40)), "the window restarts at the last flush")
        XCTAssertTrue(gate.shouldFlush(now: t0 + .milliseconds(70)))
    }

    /// 80 tok/s for one second → ~30 transcript writes, not 80. The number the UI thread feels.
    func testEightyTokensPerSecondCoalescesToAboutThirtyWrites() {
        var gate = StreamFlushGate(interval: .milliseconds(33))
        let t0 = ContinuousClock.Instant.now
        var writes = 0
        for i in 0..<80 where gate.shouldFlush(now: t0 + .milliseconds(Int64(i) * 1000 / 80)) { writes += 1 }
        XCTAssertGreaterThanOrEqual(writes, 26)   // 80 tok/s ÷ 3 tokens per 33 ms window = 27
        XCTAssertLessThanOrEqual(writes, 32)
    }
}
