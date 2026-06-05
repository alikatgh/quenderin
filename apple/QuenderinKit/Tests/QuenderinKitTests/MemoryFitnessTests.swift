import XCTest
@testable import QuenderinKit

final class MemoryFitnessTests: XCTestCase {

    private func model(_ id: String) -> ModelEntry {
        guard let entry = ModelCatalog.entry(id: id) else {
            fatalError("test fixture missing catalog id \(id)")
        }
        return entry
    }

    func testFitsComfortably() {
        // 1B (1.5 GB × 1.15 ≈ 1.7 GB) on a 16 GB device with 12 GB free.
        let result = MemoryFitness.check(model: model("llama32-1b"), totalGB: 16, freeGB: 12)
        XCTAssertTrue(result.canLoad)
        XCTAssertEqual(result.severity, .safe)
    }

    func testWarnsWhenTight() {
        // 3B (3.0 GB × 1.15 ≈ 3.45 GB) on 16 GB total with only 6 GB free
        // → usage ≈ 0.84, between the 0.65 warning and 0.85 hard budgets.
        let result = MemoryFitness.check(model: model("llama32-3b"), totalGB: 16, freeGB: 6)
        XCTAssertTrue(result.canLoad)
        XCTAssertEqual(result.severity, .warning)
    }

    func testBlocksWhenInsufficient() {
        // 8B (6.75 GB × 1.30 ≈ 8.78 GB) on an 8 GB device → cannot load.
        let result = MemoryFitness.check(model: model("llama3-8b"), totalGB: 8, freeGB: 4)
        XCTAssertFalse(result.canLoad)
        XCTAssertEqual(result.severity, .blocked)
    }

    func testLargeModelUsesLargerOverhead() {
        // paramsBillions > 3 selects the 1.30 multiplier.
        let result = MemoryFitness.check(model: model("llama3-8b"), totalGB: 64, freeGB: 64)
        XCTAssertEqual(result.requiredMemoryGB, 6.75 * 1.30, accuracy: 0.0001)
    }
}
