import XCTest
@testable import QuenderinKit

final class HardwareProbeTests: XCTestCase {

    func testCurrentProfileIsSane() {
        let profile = HardwareProbe.current()
        XCTAssertGreaterThan(profile.totalRAMGB, 0, "physical memory should be positive")
        XCTAssertGreaterThan(profile.processorCount, 0)
        XCTAssertFalse(profile.chip.isEmpty)
    }

    func testRecommendationForThisDeviceResolves() {
        // End-to-end: probe real hardware → get a real, downloadable module.
        let model = ModelRecommender.recommendedModelForThisDevice()
        XCTAssertNotNil(ModelCatalog.entry(id: model.id))
        XCTAssertNotNil(model.downloadURL)
    }
}
