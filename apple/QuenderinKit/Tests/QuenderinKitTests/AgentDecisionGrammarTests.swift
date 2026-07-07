import XCTest
import CryptoKit
@testable import QuenderinKit

/// Pins the decision grammar byte-for-byte. The Kotlin twin pins the SAME hash in CoreVerify —
/// if either platform's literal drifts (a whitespace, an escape), one build breaks instead of
/// the two agents quietly decoding under different contracts.
final class AgentDecisionGrammarTests: XCTestCase {
    /// Shared cross-platform pin — must equal CoreVerify's `GRAMMAR_SHA256`.
    static let expectedSHA256 = "0fa943fd15171ce95fa4f15a3ead3bcaed72250977041e802c892931eea382b8"

    func testGrammarHashMatchesTheCrossPlatformPin() {
        let digest = SHA256.hash(data: Data(AgentDecisionGrammar.gbnf.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.expectedSHA256,
                       "decision grammar drifted — update BOTH twins and BOTH pins together")
    }

    func testGrammarShapeSanity() {
        let g = AgentDecisionGrammar.gbnf
        XCTAssertTrue(g.hasPrefix("root ::="))
        for rule in ["tool ::=", "plan ::=", "answer ::=", "string ::=", "ws ::="] {
            XCTAssertTrue(g.contains(rule), "missing rule: \(rule)")
        }
    }

    /// The action-first grammar (tool|plan only, no answer) — same cross-platform SHA pin as
    /// CoreVerify's `ACTION_FIRST_SHA256`.
    static let expectedActionFirstSHA256 = "cd6b367d688a1971b002933935c21ee43a8e538d27c482aecfb75494b9af7f7d"

    func testActionFirstGrammarHashMatchesTheCrossPlatformPin() {
        let digest = SHA256.hash(data: Data(AgentDecisionGrammar.gbnfActionFirst.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Self.expectedActionFirstSHA256,
                       "action-first grammar drifted — update BOTH twins and BOTH pins together")
    }

    func testActionFirstGrammarForbidsAnswer() {
        let g = AgentDecisionGrammar.gbnfActionFirst
        XCTAssertTrue(g.hasPrefix("root ::= ws ( tool | plan )"))
        XCTAssertFalse(g.contains("answer"), "the whole point: {answer} must be unsampleable on step 1")
        // still a valid tool/plan grammar
        XCTAssertTrue(g.contains("tool ::=") && g.contains("plan ::=") && g.contains("ws ::="))
    }
}
