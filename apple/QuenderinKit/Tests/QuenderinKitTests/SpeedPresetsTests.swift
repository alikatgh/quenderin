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

        let tiny = SpeedPresets.forDevice(totalRAMGB: 2)
        XCTAssertEqual(tiny.fast.id, "llama32-1b-q2")
        XCTAssertEqual(tiny.balanced.id, "llama32-1b")
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

        let tiny = SpeedPresets.forDevice(totalRAMGB: 2)       // balanced == quality (llama32-1b)
        XCTAssertEqual(tiny.preset(for: tiny.balanced.id), .quality)
    }
}
