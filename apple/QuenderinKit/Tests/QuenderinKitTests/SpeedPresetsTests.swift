import XCTest
@testable import QuenderinKit

/// Twin of the Kotlin CoreVerify SpeedPresets checks — keep the two in lockstep.
final class SpeedPresetsTests: XCTestCase {

    func testBandsMapToTheRightModels() {
        let phone = SpeedPresets.forDevice(totalRAMGB: 8)      // mainstream phone
        XCTAssertEqual(phone.fast.id, "llama32-1b")
        XCTAssertEqual(phone.balanced.id, "llama32-3b")
        XCTAssertEqual(phone.quality.id, "qwen3-4b")

        let bigMac = SpeedPresets.forDevice(totalRAMGB: 18)    // desktop-class RAM
        XCTAssertEqual(bigMac.fast.id, "llama32-3b")
        XCTAssertEqual(bigMac.balanced.id, "qwen3-4b")
        XCTAssertEqual(bigMac.quality.id, "qwen3-14b")

        // 2 GB: the band's 1B-Q4 needs 1.5×1.15 = ~1.7 GB → 86% of RAM, over the 85% budget —
        // so the fitness-aware quality steps down to Q2 and the whole dial collapses onto it.
        let tiny = SpeedPresets.forDevice(totalRAMGB: 2)
        XCTAssertEqual(tiny.fast.id, "llama32-1b-q2")
        XCTAssertEqual(tiny.balanced.id, "llama32-1b-q2")
        XCTAssertEqual(tiny.quality.id, "llama32-1b-q2")
    }

    func testQualityStepsDownWhenTheBandPickIsMemoryBlocked() {
        // 16 GB: the RAM band says 14B, but loading it would use ~89% of RAM — over the 85%
        // budget. Quality (and the standalone recommendation) must step down to the largest
        // model that actually loads, not offer a doomed install.
        let sixteen = SpeedPresets.forDevice(totalRAMGB: 16)
        XCTAssertNotEqual(sixteen.quality.id, "qwen3-14b")
        XCTAssertTrue(MemoryFitness.check(model: sixteen.quality, totalGB: 16, freeGB: 16).canLoad)
        XCTAssertEqual(sixteen.quality.id, ModelRecommender.bestInstallableModel(forTotalRAMGB: 16).id)

        // Enough headroom (14.3 GB required / 85% of 18 GB budget) → the band pick stands.
        XCTAssertEqual(ModelRecommender.bestInstallableModel(forTotalRAMGB: 18).id, "qwen3-14b")
    }

    func testOrderingNeverUpsideDown() {
        for ram in [1.0, 2.0, 3.5, 6.0, 8.0, 12.0, 18.0] {
            let c = SpeedPresets.forDevice(totalRAMGB: ram)
            XCTAssertLessThanOrEqual(c.fast.ramGB, c.balanced.ramGB, "ram \(ram)")
            XCTAssertLessThanOrEqual(c.balanced.ramGB, c.quality.ramGB, "ram \(ram)")
        }
    }

    func testPresetForRoundTripsAndPrefersStrongerLabelOnCollapsedBands() {
        let c = SpeedPresets.forDevice(totalRAMGB: 8)
        XCTAssertEqual(c.preset(for: c.fast.id), .fast)
        XCTAssertEqual(c.preset(for: c.quality.id), .quality)
        XCTAssertNil(c.preset(for: "qwen25-coder-7b"))

        let tiny = SpeedPresets.forDevice(totalRAMGB: 2)       // balanced == quality (llama32-1b-q2)
        XCTAssertEqual(tiny.preset(for: tiny.balanced.id), .quality)
    }
}
