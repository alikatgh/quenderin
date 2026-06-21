import XCTest
@testable import QuenderinKit

final class ContextWindowTests: XCTestCase {
    func testScalesContextWithDeviceRAM() {
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 2), 1024)   // 2–3 GB phones
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 3.9), 1024)
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 4), 2048)   // 4 GB
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 5.9), 2048)
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 6), 4096)   // 6 GB+
        XCTAssertEqual(ContextWindow.recommend(totalRAMGB: 8), 4096)
    }

    func testFootprintAwareContext() {
        // 1B (~0.8 GB) on a 4 GB budget → lots of headroom → full context.
        XCTAssertEqual(ContextWindow.recommend(appBudgetGB: 4.0, modelWeightsGB: 0.8), 4096)
        // 7B (~6 GB) on a 4 GB budget → doesn't fit → minimal KV cache.
        XCTAssertEqual(ContextWindow.recommend(appBudgetGB: 4.0, modelWeightsGB: 6.0), 512)
        // 4B (~3.8 GB) on a 4 GB budget → tight.
        XCTAssertEqual(ContextWindow.recommend(appBudgetGB: 4.0, modelWeightsGB: 3.8), 512)
        // Same 4B on a 6 GB budget → comfortable.
        XCTAssertEqual(ContextWindow.recommend(appBudgetGB: 6.0, modelWeightsGB: 3.8), 4096)
        // 1B on a 2 GB budget → moderate headroom.
        XCTAssertEqual(ContextWindow.recommend(appBudgetGB: 2.0, modelWeightsGB: 0.8), 2048)
    }
}
