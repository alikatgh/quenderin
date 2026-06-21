import XCTest
@testable import QuenderinKit

final class ThreadPlannerTests: XCTestCase {
    func testUsesPerformanceCoreCountWhenKnown() {
        // big.LITTLE / P+E: use the P-cores, not all cores.
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: 4, totalCores: 8), 4)
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: 2, totalCores: 6), 2)
    }

    func testFallsBackToAllButOneWhenUnknown() {
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: nil, totalCores: 8), 7)
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: nil, totalCores: 1), 1)
    }

    func testClampsBogusValues() {
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: 0, totalCores: 8), 7)   // 0 → fallback
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: 99, totalCores: 8), 7)  // > total → fallback
        XCTAssertEqual(ThreadPlanner.recommend(performanceCores: 4, totalCores: 0), 1)   // total floored to 1
    }
}
