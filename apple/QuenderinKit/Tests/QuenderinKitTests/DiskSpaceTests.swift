import XCTest
@testable import QuenderinKit

final class DiskSpaceTests: XCTestCase {

    private func model(_ id: String) -> ModelEntry { ModelCatalog.entry(id: id)! }

    func testHasRoomWhenAmple() {
        let result = DiskSpace.check(model: model("llama32-1b-q2"), availableBytes: 10_000_000_000)
        XCTAssertTrue(result.hasRoom)
    }

    func testBlockedWhenNearlyFull() {
        let result = DiskSpace.check(model: model("llama3-8b"), availableBytes: 1_000_000_000)
        XCTAssertFalse(result.hasRoom)
        XCTAssertTrue(result.message.lowercased().contains("not enough"))
    }

    func testEstimateScalesWithSizeAndQuant() {
        let big = DiskSpace.estimatedDownloadBytes(for: model("llama3-8b"))
        let small = DiskSpace.estimatedDownloadBytes(for: model("llama32-1b-q2"))
        XCTAssertGreaterThan(big, small)
        XCTAssertGreaterThan(big, 3_000_000_000)   // 8B Q4_K_M ≈ 4.5 GB
        XCTAssertLessThan(small, 1_000_000_000)     // 1B Q2_K ≈ 0.33 GB
    }
}
