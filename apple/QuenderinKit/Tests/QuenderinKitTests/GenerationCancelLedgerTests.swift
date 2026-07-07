import XCTest
@testable import QuenderinKit

/// Pins the generation-scoped cancellation policy (audit S2). The old single shared Bool had two
/// live failure modes: a new generation RESET a cancel aimed at the still-running previous decode
/// (dead Stop button), and a stale stream-termination re-set it and killed the WRONG generation
/// (spuriously empty reply). Compiled unconditionally — no llama linkage needed.
final class GenerationCancelLedgerTests: XCTestCase {

    func testFreshGenerationIsNotCancelled() {
        var ledger = GenerationCancelLedger()
        let g1 = ledger.mint()
        XCTAssertFalse(ledger.isCancelled(g1))
    }

    func testCancelAllReachesEveryMintedGeneration() {
        var ledger = GenerationCancelLedger()
        let g1 = ledger.mint()
        let g2 = ledger.mint()
        ledger.cancelAll()
        XCTAssertTrue(ledger.isCancelled(g1))
        XCTAssertTrue(ledger.isCancelled(g2))
    }

    /// THE stop→resend race: Stop (cancelAll) then a new prompt. The old Bool reset lost the
    /// cancel — the old decode ran on. With ids: the old generation STAYS cancelled and the new
    /// one starts clean; nothing the new generation does can resurrect the old.
    func testStopThenNewPromptKeepsOldCancelledAndNewAlive() {
        var ledger = GenerationCancelLedger()
        let g1 = ledger.mint()
        ledger.cancelAll()               // user hits Stop while g1 decodes
        let g2 = ledger.mint()           // user immediately sends a new prompt
        XCTAssertTrue(ledger.isCancelled(g1), "the Stop must keep killing the old decode")
        XCTAssertFalse(ledger.isCancelled(g2), "the new generation must not inherit the old cancel")
    }

    /// The stale-termination race: g1's stream dies AFTER g2 already started. The old Bool set
    /// true and killed g2 (empty reply). With ids: cancel(upTo: g1) can never reach g2.
    func testLateTerminationOfOldStreamCannotKillTheNewGeneration() {
        var ledger = GenerationCancelLedger()
        let g1 = ledger.mint()
        let g2 = ledger.mint()           // new generation already minted
        ledger.cancel(upTo: g1)          // g1's onTermination fires late
        XCTAssertTrue(ledger.isCancelled(g1))
        XCTAssertFalse(ledger.isCancelled(g2), "a dead stream's termination must not kill the live one")
    }

    func testCancelUpToNeverMovesBackwards() {
        var ledger = GenerationCancelLedger()
        let g1 = ledger.mint()
        let g2 = ledger.mint()
        ledger.cancelAll()               // cancels through g2
        ledger.cancel(upTo: g1)          // late, lower bound — must not UN-cancel g2
        XCTAssertTrue(ledger.isCancelled(g2))
    }
}
