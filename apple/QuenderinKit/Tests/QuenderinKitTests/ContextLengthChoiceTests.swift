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

    func testManualAtOrBelowAutoHasNoWarning() {
        let resolved = ContextWindow.resolve(choice: .k2, appBudgetGB: 6.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(resolved.tokens, 2048)
        XCTAssertNil(resolved.warning)
        XCTAssertNil(resolved.warningText)

        let equalAuto = ContextWindow.resolve(choice: .k4, appBudgetGB: 4.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(equalAuto.tokens, 4096)
        XCTAssertNil(equalAuto.warning)
        XCTAssertNil(equalAuto.warningText)
    }

    func testManualAboveAutoThatFitsReturnsMoreMemoryWarning() {
        let resolved = ContextWindow.resolve(choice: .k8, appBudgetGB: 12.0, modelWeightsGB: 4.0, kvCacheType: .f16)
        XCTAssertEqual(resolved.tokens, 8192)
        XCTAssertEqual(resolved.warning, .moreMemory)
        XCTAssertEqual(resolved.warningText, "Uses more memory. Long chats may be slower.")
    }

    func testManualExceedingHeadroomClampsToAutoWithWarning() {
        let clamped4k = ContextWindow.resolve(choice: .k8, appBudgetGB: 4.0, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(clamped4k.tokens, 4096)
        XCTAssertEqual(clamped4k.warning, .exceedsBudget)
        XCTAssertEqual(clamped4k.warningText, "Not enough memory on this device for this length; using 4096 tokens.")

        let clamped1k = ContextWindow.resolve(choice: .k2, appBudgetGB: 2.0, modelWeightsGB: 1.5, kvCacheType: .f16)
        XCTAssertEqual(clamped1k.tokens, 1024)
        XCTAssertEqual(clamped1k.warning, .exceedsBudget)
        XCTAssertEqual(clamped1k.warningText, "Not enough memory on this device for this length; using 1024 tokens.")
    }

    func testQuantizedKVCacheUnlocksLongerManualContext() {
        let f16Res = ContextWindow.resolve(choice: .k4, appBudgetGB: 3.4, modelWeightsGB: 2.0, kvCacheType: .f16)
        XCTAssertEqual(f16Res.tokens, 2048)
        XCTAssertEqual(f16Res.warning, .exceedsBudget)

        let q8Res = ContextWindow.resolve(choice: .k4, appBudgetGB: 3.4, modelWeightsGB: 2.0, kvCacheType: .q8_0)
        XCTAssertEqual(q8Res.tokens, 4096)
        XCTAssertEqual(q8Res.warning, .moreMemory)
    }
}
