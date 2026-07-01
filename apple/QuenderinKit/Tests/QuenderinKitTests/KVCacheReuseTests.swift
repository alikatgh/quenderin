import XCTest
@testable import QuenderinKit

/// Incremental-decode planning: chat reuses the KV cache across turns. A pure extension reuses the whole
/// cache; a front-drop (the context window slid and evicted the oldest turn) now reuses the surviving
/// tail via a context-shift instead of re-prefilling everything; anything unusable falls back to a clean
/// full prefill (fail-safe). Twin of Android `KVCacheReuse` — keep the two in lockstep with `CoreVerify.kt`.
final class KVCacheReuseTests: XCTestCase {
    func testFirstTurnClears() {
        XCTAssertEqual(KVCacheReuse.plan(cached: [], new: [1, 2, 3]),
                       .init(clearCache: true, decodeFrom: 0))
    }

    func testPureAppendReusesPrefixAndDecodesOnlyTheSuffix() {
        // KV holds [1,2,3] (BOS + prior turn); the new prompt extends it with [4,5].
        let plan = KVCacheReuse.plan(cached: [1, 2, 3], new: [1, 2, 3, 4, 5])
        XCTAssertEqual(plan, .init(clearCache: false, decodeFrom: 3), "decode only [4,5], reuse [1,2,3]")
    }

    func testContextShiftReusesSurvivingTailAfterOldestTurnDropped() {
        // system=[1,2], dropped turn=[3,4], surviving turns=[5,6,7], appended new turn=[8].
        // cache = system+dropped+surviving; new = system+surviving+newturn.
        let plan = KVCacheReuse.plan(cached: [1, 2, 3, 4, 5, 6, 7], new: [1, 2, 5, 6, 7, 8])
        // Evict cache positions [2,4) (the dropped turn), shift survivors down, decode only new[5:]=[8].
        XCTAssertEqual(plan, .init(clearCache: false, decodeFrom: 5, evictFrom: 2, evictTo: 4))
    }

    func testPicksSmallestGapForMaximalReuse() {
        // After prefix [1,8], dropping g=1 ([8]) realigns the tail [2,2]; g=2 also aligns but reuses less.
        let cached: [Int32] = [1, 8, 8, 2, 2]
        let new: [Int32] = [1, 8, 2, 2, 9]
        let plan = KVCacheReuse.plan(cached: cached, new: new)
        XCTAssertEqual(plan, .init(clearCache: false, decodeFrom: 4, evictFrom: 2, evictTo: 3))
        XCTAssertEqual(simulateReuse(cached: cached, new: new, plan: plan), new, "plan must reconstruct new exactly")
    }

    func testDivergedHistoryFallsBackToPrefixOnlyReuse() {
        // token 2 changed and no tail realigns → keep just the common prefix [1], decode the rest.
        // Better than the old full reprefill (saves the shared prefix), still 100% safe.
        let plan = KVCacheReuse.plan(cached: [1, 2, 3], new: [1, 9, 3, 4])
        XCTAssertEqual(plan, .init(clearCache: false, decodeFrom: 1, evictFrom: 1, evictTo: 3))
    }

    func testChangedSystemPromptFullyReprefills() {
        // No common prefix at all → nothing to reuse → clear + reprefill.
        XCTAssertEqual(KVCacheReuse.plan(cached: [1, 2, 3, 4], new: [9, 2, 3, 4, 5]),
                       .init(clearCache: true, decodeFrom: 0))
    }

    func testIdenticalOrShorterPromptClears() {
        // Not a STRICT prefix (no new tokens to decode) → clear, so we never decode an empty batch.
        XCTAssertEqual(KVCacheReuse.plan(cached: [1, 2, 3], new: [1, 2, 3]),
                       .init(clearCache: true, decodeFrom: 0))
        // New prompt shorter than the cache (history shrank) → clear.
        XCTAssertEqual(KVCacheReuse.plan(cached: [1, 2, 3, 4], new: [1, 2]),
                       .init(clearCache: true, decodeFrom: 0))
    }

    func testContextShiftReconstructsNewPromptExactly() {
        // sys[10,11] + drop[20,21,22] + keep[30,31,32,33]  →  sys + keep + newturn[40].
        let cached: [Int32] = [10, 11, 20, 21, 22, 30, 31, 32, 33]
        let new: [Int32] = [10, 11, 30, 31, 32, 33, 40]
        let plan = KVCacheReuse.plan(cached: cached, new: new)
        XCTAssertEqual(simulateReuse(cached: cached, new: new, plan: plan), new)
    }

    /// Reproduce the native executor purely on the token mirror: evict `[evictFrom, evictTo)`, shift the
    /// survivors down (concatenation models the position shift), then decode `new[decodeFrom:]`. Returns
    /// the sequence the cache should hold, or nil if the plan is internally inconsistent. A correct plan
    /// always reconstructs `new` — the safety invariant.
    private func simulateReuse(cached: [Int32], new: [Int32], plan: KVCacheReuse.Plan) -> [Int32]? {
        if plan.clearCache { return new }
        let kept = Array(cached[0..<plan.evictFrom]) + Array(cached[plan.evictTo..<cached.count])
        guard kept.count == plan.decodeFrom else { return nil }
        return kept + Array(new[plan.decodeFrom..<new.count])
    }
}
