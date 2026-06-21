import XCTest
@testable import QuenderinKit

/// KV-cache quantization: on a memory-tight phone, a q8_0 cache halves the per-token cost so the
/// same KV memory holds ~2× the context — the difference between a 512-token stub and a usable chat.
final class KVCachePolicyTests: XCTestCase {

    func testRoomyDeviceKeepsFullPrecision() {
        // 6 GB budget, a 1B (~0.8 GB weights) → ~5 GB headroom → f16 is affordable.
        XCTAssertEqual(KVCachePolicy.recommend(appBudgetGB: 6.0, modelWeightsGB: 0.8), .f16)
    }

    func testTightDeviceQuantizesCache() {
        // ~2 GB budget, a 4B (~2.4 GB weights) leaves < 1.2 GB headroom → q8_0.
        XCTAssertEqual(KVCachePolicy.recommend(appBudgetGB: 2.0, modelWeightsGB: 1.4), .q8_0)
        // A very constrained device still quantizes (never silently over-allocates an f16 cache).
        XCTAssertEqual(KVCachePolicy.recommend(appBudgetGB: 1.2, modelWeightsGB: 0.8), .q8_0)
    }

    func testQuantizedCacheBuysMoreContextForSameMemory() {
        let budget = 1.4, weights = 0.8   // tight: f16 band would be 512–1024
        let f16Ctx = ContextWindow.recommend(appBudgetGB: budget, modelWeightsGB: weights, kvCacheType: .f16)
        let q8Ctx  = ContextWindow.recommend(appBudgetGB: budget, modelWeightsGB: weights, kvCacheType: .q8_0)
        XCTAssertGreaterThan(q8Ctx, f16Ctx, "q8_0 must yield a longer context than f16 for the same memory")
        // The freed memory is spent on tokens, not lost: tokens × per-token-cost is ~constant.
        let f16Mem = Double(f16Ctx) * KVCacheType.f16.relativeCostPerToken
        let q8Mem  = Double(q8Ctx)  * KVCacheType.q8_0.relativeCostPerToken
        XCTAssertEqual(q8Mem, f16Mem, accuracy: 256.0, "KV memory is preserved, just holds more tokens")
    }

    func testF16OverloadMatchesTheTwoArgVersion() {
        // Passing .f16 must not change the long-standing footprint-aware behaviour.
        for (b, w) in [(8.0, 0.8), (3.0, 2.4), (2.0, 1.4), (1.1, 0.8)] {
            XCTAssertEqual(
                ContextWindow.recommend(appBudgetGB: b, modelWeightsGB: w, kvCacheType: .f16),
                ContextWindow.recommend(appBudgetGB: b, modelWeightsGB: w),
                "f16 overload should equal the 2-arg version for (\(b), \(w))")
        }
    }

    func testContextIsClampedAndQuantized() {
        // Whatever the scaling, n_ctx stays in [256, 8192] and on a 256-token grid.
        for type in [KVCacheType.f16, .q8_0] {
            let n = ContextWindow.recommend(appBudgetGB: 16.0, modelWeightsGB: 0.5, kvCacheType: type)
            XCTAssertLessThanOrEqual(n, 8192)
            XCTAssertGreaterThanOrEqual(n, 256)
            XCTAssertEqual(n % 256, 0, "n_ctx should be a 256-token multiple")
        }
    }
}
