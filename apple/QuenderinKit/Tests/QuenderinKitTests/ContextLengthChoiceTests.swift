import XCTest
@testable import QuenderinKit

final class ContextLengthChoiceTests: XCTestCase {
    func testChoiceRawValuesAndDefault() {
        XCTAssertEqual(ContextLengthChoice.defaultChoice, .auto)
        XCTAssertEqual(ContextLengthChoice.auto.rawValue, "auto")
        XCTAssertEqual(ContextLengthChoice.k2.rawValue, "2048")
        XCTAssertEqual(ContextLengthChoice.k4.rawValue, "4096")
        XCTAssertEqual(ContextLengthChoice.k8.rawValue, "8192")
    }

    func testAutoMatchesThreeArgRecommendExactlyWithNoWarning() {
        let cases: [(Double, Double, KVCacheType)] = [
            (2.0, 1.5, .f16),
            (2.0, 1.5, .q8_0),
            (4.0, 2.0, .f16),
            (4.0, 2.0, .q8_0),
            (12.0, 4.0, .f16),
            (12.0, 4.0, .q8_0),
        ]
        for (budget, weights, kv) in cases {
            let expected = ContextWindow.recommend(appBudgetGB: budget, modelWeightsGB: weights, kvCacheType: kv)
            let resolved = ContextWindow.resolve(choice: .auto, appBudgetGB: budget, modelWeightsGB: weights, kvCacheType: kv)
            XCTAssertEqual(resolved.tokens, expected)
            XCTAssertNil(resolved.warning)
            XCTAssertNil(resolved.warningText)
        }
    }

    func testManualAtOrBelowAutoHasNoWarningWhenItFits() {
        let resolved = ContextWindow.resolve(choice: .k2, appBudgetGB: 6.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(resolved.tokens, 2048)
        XCTAssertNil(resolved.warning)
        XCTAssertNil(resolved.warningText)

        // Roomy device: headroom = 6.0 - 2.3 = 3.7 GiB; 4096 f16 KV = 2.0 GiB <= 3.7 GiB, auto = 4096.
        let equalAutoFits = ContextWindow.resolve(choice: .k4, appBudgetGB: 6.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(equalAutoFits.tokens, 4096)
        XCTAssertNil(equalAutoFits.warning)
        XCTAssertNil(equalAutoFits.warningText)

        // Manual choice <= auto MUST STILL be checked against estimated KV headroom:
        // headroom = 4.0 - 2.3 = 1.7 GiB; 4096 f16 KV = 2.0 GiB > 1.7 GiB -> clamps to 2048 with .exceedsBudget.
        let equalAutoExceeds = ContextWindow.resolve(choice: .k4, appBudgetGB: 4.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(equalAutoExceeds.tokens, 2048)
        XCTAssertEqual(equalAutoExceeds.warning, .exceedsBudget)
        XCTAssertEqual(equalAutoExceeds.warningText, "Not enough memory on this device for this length; using 2048 tokens.")
    }

    func testManualAboveAutoThatFitsReturnsMoreMemoryWarning() {
        let resolved = ContextWindow.resolve(choice: .k8, appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16)
        XCTAssertEqual(resolved.tokens, 8192)
        XCTAssertEqual(resolved.warning, .moreMemory)
        XCTAssertEqual(resolved.warningText, "Uses more memory. Long chats may be slower.")
    }

    func testManualExceedingHeadroomClampsToLargestFittingTierWithWarning() {
        // headroom = 6.0 - 2.3 = 3.7 GiB; 8192 f16 needs 4.0 GiB (no), 4096 needs 2.0 GiB (yes) -> 4096.
        let clamped4k = ContextWindow.resolve(choice: .k8, appBudgetGB: 6.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(clamped4k.tokens, 4096)
        XCTAssertEqual(clamped4k.warning, .exceedsBudget)
        XCTAssertEqual(clamped4k.warningText, "Not enough memory on this device for this length; using 4096 tokens.")

        // headroom = 4.0 - 2.3 = 1.7 GiB; 8192 (4.0) and 4096 (2.0) don't fit; 2048 (1.0) fits -> 2048.
        let clamped2k = ContextWindow.resolve(choice: .k8, appBudgetGB: 4.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(clamped2k.tokens, 2048)
        XCTAssertEqual(clamped2k.warning, .exceedsBudget)
        XCTAssertEqual(clamped2k.warningText, "Not enough memory on this device for this length; using 2048 tokens.")

        // Very tight device: headroom = 2.0 - 1.725 = 0.275 GiB; even 2048 doesn't fit -> never below 2048.
        let clampedFloor = ContextWindow.resolve(choice: .k2, appBudgetGB: 2.0, modelWeightsGB: 1.5, kvCacheType: .f16)
        XCTAssertEqual(clampedFloor.tokens, 2048)
        XCTAssertEqual(clampedFloor.warning, .exceedsBudget)
        XCTAssertEqual(clampedFloor.warningText, "Not enough memory on this device for this length; using 2048 tokens.")
    }

    func testQuantizedKVCacheUnlocksLongerManualContext() {
        let f16Res = ContextWindow.resolve(choice: .k4, appBudgetGB: 3.4, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(f16Res.tokens, 2048)
        XCTAssertEqual(f16Res.warning, .exceedsBudget)

        let q8Res = ContextWindow.resolve(choice: .k4, appBudgetGB: 3.4, modelWeightsGB: 2.0, kvCacheType: .q8_0)
        XCTAssertEqual(q8Res.tokens, 4096)
        XCTAssertEqual(q8Res.warning, .moreMemory)
    }

    func testResolveForLoadAppliesOptionalModelCap() {
        XCTAssertEqual(
            ContextWindow.resolveForLoad(choice: .auto, appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16),
            ContextWindow.recommend(appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16)
        )
        XCTAssertEqual(
            ContextWindow.resolveForLoad(choice: .k8, appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16),
            8192
        )
        XCTAssertEqual(
            ContextWindow.resolveForLoad(choice: .k8, appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16, maxContextTokens: 4096),
            4096
        )
        XCTAssertEqual(
            ContextWindow.resolveForLoad(choice: .k8, appBudgetGB: 6.0, modelWeightsGB: 2.0, kvCacheType: .f16, maxContextTokens: 8192),
            4096
        )
        XCTAssertEqual(
            ContextWindow.resolveForLoad(choice: .k8, appBudgetGB: 4.0, modelWeightsGB: 2.0, kvCacheType: .f16, maxContextTokens: 8192),
            2048
        )
    }
}
