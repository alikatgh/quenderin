import XCTest
@testable import QuenderinKit

/// Ported 1:1 from `quenderin/tests/recommended-model.test.ts` so the Swift
/// recommender and the TypeScript recommender stay behaviorally identical.
final class ModelRecommenderTests: XCTestCase {

    func testRecommendsUltraLightBelow1_5GB() {
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 0.5), "llama32-1b-q2")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 1),   "llama32-1b-q2")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 1.49), "llama32-1b-q2")
    }

    func testRecommends1BFrom1_5UpToUnder3() {
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 1.5),  "llama32-1b")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 2.99), "llama32-1b")
    }

    func testRecommends3BFrom3UpToUnder4() {
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 3),    "llama32-3b")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 3.99), "llama32-3b")
    }

    func testRecommendsQwen3From4UpToUnder10() {
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 4),    "qwen3-4b")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 8),    "qwen3-4b")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 9.99), "qwen3-4b")
    }

    func testRecommendsQwen3_14BAt10AndAbove() {
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 10), "qwen3-14b")
        XCTAssertEqual(ModelRecommender.recommendedModelID(forTotalRAMGB: 18), "qwen3-14b")
    }

    func testEveryRecommendedIDResolvesToACatalogEntry() {
        for ram in [0.5, 1.49, 1.5, 2.99, 3, 5.99, 6, 18, 64] {
            let id = ModelRecommender.recommendedModelID(forTotalRAMGB: ram)
            XCTAssertNotNil(ModelCatalog.entry(id: id), "id \(id) (ram \(ram)) missing from catalog")
        }
    }

    func testHardwareTierRecommendation() {
        // 8 GB device → 8B params, Q4_K_M (the 8–12 GB tier).
        let rec = ModelRecommender.recommendation(forTotalRAMGB: 8)
        XCTAssertEqual(rec.maxParamsBillions, 8)
        XCTAssertEqual(rec.quantization, "Q4_K_M")
        // Below the smallest tier → the safe 1B floor, never a crash.
        XCTAssertEqual(ModelRecommender.recommendation(forTotalRAMGB: 0.25).maxParamsBillions, 1)
    }

    func testCatalogIntegrity() {
        XCTAssertEqual(ModelCatalog.models.count, 12)
        for model in ModelCatalog.models {
            XCTAssertNotNil(model.downloadURL, "\(model.id) has a malformed URL")
            XCTAssertNotNil(Quantization.info(id: model.quantization), "\(model.id) uses unknown quant \(model.quantization)")
        }
        XCTAssertEqual(ModelCatalog.smallest.id, "llama32-1b-q2")
    }
}
