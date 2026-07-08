import XCTest
@testable import QuenderinKit

/// The stop-sequence scanner is the enabling piece for a "think, then decide" agent pass — it must
/// halt exactly at a stop sequence even when that sequence arrives split across several tokens, and
/// it must never eat text when no stop appears. Pure logic; no engine needed.
final class StopSequenceScannerTests: XCTestCase {

    /// Drive a scanner with a list of pieces; return (all emitted text, whether a stop fired).
    private func run(_ pieces: [String], stops: [String]) -> (emitted: String, stopped: Bool) {
        var s = StopSequenceScanner(stops: stops)
        var out = ""
        var stopped = false
        for p in pieces {
            let (emit, stop) = s.feed(p)
            out += emit
            if stop { stopped = true; break }
        }
        if !stopped { out += s.flush() }
        return (out, stopped)
    }

    func testNoStopsIsInertAndPassesEverythingThrough() {
        let s = StopSequenceScanner(stops: [])
        XCTAssertFalse(s.isActive)
        let (out, stopped) = run(["hello ", "world"], stops: [])
        XCTAssertEqual(out, "hello world")
        XCTAssertFalse(stopped)
    }

    func testStopWithinASinglePieceEmitsTheTextBeforeItAndHalts() {
        let (out, stopped) = run(["thinking done</think>the answer"], stops: ["</think>"])
        XCTAssertEqual(out, "thinking done")
        XCTAssertTrue(stopped)
    }

    /// The load-bearing case: the stop sequence is split across tokens ("</thi" + "nk>").
    func testStopSplitAcrossPiecesStillHaltsCleanly() {
        let (out, stopped) = run(["hel", "lo</thi", "nk>rest"], stops: ["</think>"])
        XCTAssertEqual(out, "hello", "must emit exactly the text before a token-straddling stop")
        XCTAssertTrue(stopped)
    }

    /// A partial stop that never completes must be released in full, not swallowed.
    func testUncompletedPartialStopIsReleasedOnFlush() {
        let (out, stopped) = run(["hello</th"], stops: ["</think>"])
        XCTAssertEqual(out, "hello</th")
        XCTAssertFalse(stopped)
    }

    func testEmitsNothingWhenTheStopIsAtTheVeryStart() {
        let (out, stopped) = run(["</think>only reasoning was wanted"], stops: ["</think>"])
        XCTAssertEqual(out, "")
        XCTAssertTrue(stopped)
    }

    func testHonorsTheEarliestOfSeveralStops() {
        let (out, stopped) = run(["abcSTOPdef</think>"], stops: ["</think>", "STOP"])
        XCTAssertEqual(out, "abc")
        XCTAssertTrue(stopped)
    }

    /// A long run with no stop must stream out whole (nothing permanently held back).
    func testLongTextWithNoStopStreamsCompletely() {
        let text = String(repeating: "quenderin ", count: 50)
        let (out, stopped) = run(text.map(String.init), stops: ["</think>"])
        XCTAssertEqual(out, text)
        XCTAssertFalse(stopped)
    }
}
