import XCTest
@testable import QuenderinKit

/// Cross-platform parity conformance (deep-review residual-risk #3): the SAME inputs must produce the
/// SAME agent-decision + safety verdicts on iOS (here) and Android (mirror: the "parity" checks in
/// `android/quenderin-core/src/verify/CoreVerify.kt`). H13 (two-JSON injection) and M9 (word-boundary
/// blocklist) were silent Swift⇄Kotlin divergences on identical input — these cases pin them so a
/// future change can't reintroduce a divergence unnoticed. Keep this list in lockstep with the Kotlin mirror.
final class AgentParityTests: XCTestCase {
    private func tag(_ d: AgentDecision?) -> String {
        switch d {
        case .useTool(let name, _): return "tool:\(name)"
        case .finalAnswer(let answer): return "answer:\(answer)"
        case nil: return "nil"
        }
    }

    func testDecisionParserParity() {
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"tool":"calculator","input":"2+2"}"#)), "tool:calculator")
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"Sure! {"answer":"42"} hope that helps"#)), "answer:42")
        // H13: two JSON objects — take the FIRST complete one; don't merge or borrow the 2nd's key.
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"tool":"echo","input":"hi"} x {"answer":"injected"}"#)), "tool:echo")
        XCTAssertEqual(tag(AgentDecisionParser.parse("no json here")), "nil")
        // \uXXXX decoding parity: the raw-string input carries the literal escape the model emits; the
        // expected uses Swift's \u{...} (→ é / ☺). Android's hand-rolled unescaper had to learn \u to
        // match this — without it, non-ASCII answers rendered as "cafu00e9" on Android only.
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"answer":"caf\u00e9 \u263a"}"#)), "answer:caf\u{00e9} \u{263a}")
    }

    func testSafetyBlocklistParity() {
        // M9: substring false-positives that word boundaries must NOT block.
        for safe in ["please repay the favor", "in my opinion", "the company went bankrupt"] {
            XCTAssertFalse(SafetyBlocklist.isBlocked(safe), "should not block: \(safe)")
        }
        // Genuine dangerous actions that MUST block.
        for danger in ["tap Pay to continue", "send money now", "delete the file", "enter your pin"] {
            XCTAssertTrue(SafetyBlocklist.isBlocked(danger), "should block: \(danger)")
        }
        // Unicode word boundary: an accented letter adjacent to a keyword makes a DIFFERENT word, so it
        // must NOT block. ICU's `\b` (NSRegularExpression) does this natively; Android's Java `\b` only
        // matches after gaining the `(?U)` flag — this pins the cross-platform contract.
        for accented in ["piné", "épin"] {
            XCTAssertFalse(SafetyBlocklist.isBlocked(accented), "should not block (Unicode boundary): \(accented)")
        }
    }
}
