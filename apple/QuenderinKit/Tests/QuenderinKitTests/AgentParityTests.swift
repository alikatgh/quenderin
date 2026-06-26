import XCTest
@testable import QuenderinKit

/// Cross-platform parity conformance (deep-review residual-risk #3): the SAME inputs must produce the
/// SAME agent-decision + safety verdicts on iOS (here) and Android (mirror: the "parity" checks in
/// `android/quenderin-core/src/verify/CoreVerify.kt`). H13 (two-JSON injection) and M9 (word-boundary
/// blocklist) were silent Swift-Kotlin divergences on identical input - these cases pin them so a
/// future change can't reintroduce a divergence unnoticed.
///
/// Each assertion carries a `parity:<id>` marker matching a vector in `shared/agent-parity-vectors.json`;
/// `scripts/check_agent_parity.py` (CI: `npm run check:agent-parity`) asserts every canonical id is
/// covered on BOTH platforms with no orphans, so the lockstep is machine-enforced, not just a comment.
final class AgentParityTests: XCTestCase {
    private func tag(_ d: AgentDecision?) -> String {
        switch d {
        case .useTool(let name, _): return "tool:\(name)"
        case .finalAnswer(let answer): return "answer:\(answer)"
        case nil: return "nil"
        }
    }

    func testDecisionParserParity() {
        // parity:decision-tool-call
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"tool":"calculator","input":"2+2"}"#)), "tool:calculator")
        // parity:decision-prose-answer
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"Sure! {"answer":"42"} hope that helps"#)), "answer:42")
        // parity:decision-h13-first-object - two JSON objects: take the FIRST complete one; don't merge or borrow the 2nd's key.
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"tool":"echo","input":"hi"} x {"answer":"injected"}"#)), "tool:echo")
        // parity:decision-non-json-nil
        XCTAssertEqual(tag(AgentDecisionParser.parse("no json here")), "nil")
        // parity:decision-unicode-escape - the raw-string input carries the literal \uXXXX escape the model emits;
        // the expected uses Swift's \u{...} (cafe-acute + smiley). Android's hand-rolled unescaper had to learn \u
        // to match this - without it, non-ASCII answers rendered as "cafu00e9" on Android only.
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"answer":"caf\u00e9 \u263a"}"#)), "answer:caf\u{00e9} \u{263a}")
        // parity:decision-short-escape - \t and \n must decode to a real tab/newline (Foundation JSONDecoder does
        // this natively; pinned because the Kotlin twin's hand-rolled unescaper must implement it explicitly).
        XCTAssertEqual(tag(AgentDecisionParser.parse(#"{"answer":"a\tb\nc"}"#)), "answer:a\tb\nc")
    }

    func testSafetyBlocklistParity() {
        // parity:blocklist-safe-substrings - M9: substring false-positives that word boundaries must NOT block.
        for safe in ["please repay the favor", "in my opinion", "the company went bankrupt"] {
            XCTAssertFalse(SafetyBlocklist.isBlocked(safe), "should not block: \(safe)")
        }
        // parity:blocklist-dangerous - genuine dangerous actions that MUST block.
        for danger in ["tap Pay to continue", "send money now", "delete the file", "enter your pin"] {
            XCTAssertTrue(SafetyBlocklist.isBlocked(danger), "should block: \(danger)")
        }
        // parity:blocklist-unicode-boundary - an accented letter adjacent to a keyword makes a DIFFERENT word, so it
        // must NOT block. ICU's `\b` (NSRegularExpression) does this natively; Android's Java `\b` only
        // matches after gaining the `(?U)` flag - this pins the cross-platform contract.
        for accented in ["piné", "épin"] {
            XCTAssertFalse(SafetyBlocklist.isBlocked(accented), "should not block (Unicode boundary): \(accented)")
        }
    }
}
