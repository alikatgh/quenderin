import XCTest
@testable import QuenderinKit

final class InferenceEngineTests: XCTestCase {

    func testGenerateRequiresLoadedModel() async {
        let engine = MockInferenceEngine()
        do {
            _ = try await engine.generate(prompt: "hi", options: .init())
            XCTFail("expected modelNotLoaded before any load()")
        } catch let error as InferenceError {
            XCTAssertEqual(error, .modelNotLoaded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCompleteAccumulatesStreamedTokens() async throws {
        let engine = MockInferenceEngine(cannedReply: "one two three")
        try await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))

        let id = await engine.loadedModelID()
        XCTAssertEqual(id, "llama32-1b-q2")

        let text = try await engine.complete(prompt: "hi")
        XCTAssertEqual(text, "one two three")
    }

    func testUnloadClearsLoadedModel() async throws {
        let engine = MockInferenceEngine()
        try await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/dev/null"))
        await engine.unload()
        let id = await engine.loadedModelID()
        XCTAssertNil(id)
    }
}
