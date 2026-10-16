import XCTest
@testable import QuenderinKit

final class MuseRuntimeTests: XCTestCase {
    private var imported: ModelEntry {
        ModelEntry(id: "hf:Muse_Spark_Open", label: "Imported", filename: "metadata.gguf", ramGB: 0.01,
                   sizeLabel: "13 MB", paramsBillions: 42, quantization: "Q2_K",
                   urlString: "https://example.invalid/metadata.gguf", sha256: nil)
    }

    func testMuseIdentityCannotUnderstateMemoryOrBypassManifest() {
        XCTAssertTrue(ModelRuntimeSupport.isMuse(imported))
        XCTAssertFalse(ModelRuntimeSupport.supports(imported))
        let unavailable = MemoryFitness.check(model: imported, totalGB: 1024, freeGB: 1024, museRuntimeAvailable: false)
        XCTAssertFalse(unavailable.canLoad)
        XCTAssertEqual(unavailable.message, ModelRuntimeSupport.museUnavailableMessage)
        let tooSmall = MemoryFitness.check(model: imported, totalGB: 256, freeGB: 256, museRuntimeAvailable: true)
        XCTAssertFalse(tooSmall.canLoad)
        XCTAssertEqual(tooSmall.requiredMemoryGB, 429, accuracy: 1e-8)
        XCTAssertTrue(MemoryFitness.check(model: imported, totalGB: 1024, freeGB: 1024, museRuntimeAvailable: true).canLoad)
        XCTAssertEqual(ModelRuntimeSupport.museMaxContextTokens, 4096)
    }

    func testMuseIsExcludedFromAutomaticRouting() {
        XCTAssertNil(ModelRouter.route(prompt: "Hello", installed: [imported], totalRAMGB: 1024, freeRAMGB: 1024))
    }
}
