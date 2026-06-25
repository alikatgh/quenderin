import XCTest
@testable import QuenderinKit

/// Incremental-decode planning: chat reuses the KV cache across turns when the new prompt is a pure
/// extension of the last one, and falls back to a clean full prefill on any divergence (fail-safe).
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

    func testDivergedHistoryFallsBackToFullReprefill() {
        // The window slid: token 2 changed → not a strict prefix → safe full reprefill.
        XCTAssertEqual(KVCacheReuse.plan(cached: [1, 2, 3], new: [1, 9, 3, 4]),
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
}
