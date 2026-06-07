import XCTest
@testable import QuenderinKit

/// The device knowledge behind world-class picking: the curated iPhone table, the
/// jetsam-budget model, and the chip throughput ordering.
final class AppleSiliconTests: XCTestCase {

    func testDeviceTableResolvesKeyiPhones() {
        let pro = AppleDeviceDatabase.device(forIdentifier: "iPhone16,1")
        XCTAssertEqual(pro?.name, "iPhone 15 Pro")
        XCTAssertEqual(pro?.chip, .a17Pro)
        XCTAssertEqual(pro?.totalRAMGB, 8)

        XCTAssertEqual(AppleDeviceDatabase.device(forIdentifier: "iPhone17,1")?.chip, .a18Pro)
        XCTAssertEqual(AppleDeviceDatabase.device(forIdentifier: "iPhone12,8")?.totalRAMGB, 3)

        // Macs / simulators / unknown identifiers don't resolve (→ live-probe fallback).
        XCTAssertNil(AppleDeviceDatabase.device(forIdentifier: "MacBookPro18,3"))
        XCTAssertNil(AppleDeviceDatabase.device(forIdentifier: "arm64"))
    }

    /// The core correctness property of iOS picking: the usable budget is well BELOW
    /// total RAM (that's jetsam), and the increased-memory entitlement raises it.
    func testJetsamBudgetIsBelowTotalRAM() {
        for ram in [3.0, 4.0, 6.0, 8.0] {
            let budget = AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: ram)
            XCTAssertLessThan(budget, ram, "budget must sit below total RAM (jetsam reality)")
            XCTAssertGreaterThan(budget, ram * 0.4, "but not absurdly low with the entitlement")
        }
        XCTAssertGreaterThan(
            AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: 8, increasedMemoryLimitEntitlement: true),
            AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: 8, increasedMemoryLimitEntitlement: false)
        )
    }

    func testChipScoresAreMonotonicByGeneration() {
        XCTAssertLessThan(AppleChip.a12.inferenceScore, AppleChip.a13.inferenceScore)
        XCTAssertLessThan(AppleChip.a13.inferenceScore, AppleChip.a15.inferenceScore)
        XCTAssertLessThan(AppleChip.a15.inferenceScore, AppleChip.a17Pro.inferenceScore)
        XCTAssertLessThan(AppleChip.a17Pro.inferenceScore, AppleChip.a18Pro.inferenceScore)
        XCTAssertEqual(AppleChip.a18Pro.inferenceScore, 1.0, "A18 Pro is the reference (1.0)")
    }

    func testEveryKnownDeviceHasASaneProfile() {
        for (id, device) in AppleDeviceDatabase.known {
            XCTAssertTrue(id.hasPrefix("iPhone"), "table is iPhones only")
            XCTAssertGreaterThanOrEqual(device.totalRAMGB, 3, "\(device.name) below the LLM floor")
            XCTAssertNotEqual(device.chip, .unknown, "\(device.name) must have a known chip")
        }
    }
}
