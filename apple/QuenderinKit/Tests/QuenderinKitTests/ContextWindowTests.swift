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
}
