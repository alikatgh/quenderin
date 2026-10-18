import XCTest
@testable import QuenderinKit

final class ModelPickerTests: XCTestCase {

    private func fitnessByID(forTotalRAMGB ram: Double) -> [String: MemoryCheckResult] {
        Dictionary(uniqueKeysWithValues:
            ModelCatalog.optionsWithFitness(forTotalRAMGB: ram).map { ($0.model.id, $0.fitness) }
        )
    }

    func testLowRAMBlocksLargeModelsButAllowsTiny() {
        let fitness = fitnessByID(forTotalRAMGB: 2)
        XCTAssertFalse(fitness["llama3-8b"]!.canLoad, "8B must not load on a 2 GB device")
        XCTAssertTrue(fitness["llama32-1b-q2"]!.canLoad, "the ultra-light model must load on 2 GB")
    }

    func testHighRAMAllowsEverySupportedModel() {
        let options = ModelCatalog.optionsWithFitness(forTotalRAMGB: 1024)
        XCTAssertEqual(options.count, 28)
        XCTAssertEqual(Set(options.map { $0.model.id }), Set(ModelCatalog.models.map(\.id)))
        XCTAssertEqual(options.first { $0.model.id == "beam-1.0-501b-a23b-ud-iq2-xxs" }?.model.artifacts?.count, 4)
        XCTAssertTrue(options.allSatisfy { $0.fitness.canLoad == ModelRuntimeSupport.supports($0.model) })
    }

    func testMuseDoesNotFitOn64GB() {
        let fitness = fitnessByID(forTotalRAMGB: 64)
        XCTAssertFalse(fitness["muse-spark-open-q2-k"]!.canLoad)
    }
}
