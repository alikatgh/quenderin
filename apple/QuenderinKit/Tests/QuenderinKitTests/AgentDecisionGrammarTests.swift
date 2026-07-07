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
}
