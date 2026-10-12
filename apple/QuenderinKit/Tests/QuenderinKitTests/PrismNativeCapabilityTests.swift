import XCTest
@testable import QuenderinKit
#if canImport(llama) && QUENDERIN_PRISM_LLAMA
import llama
#endif

/// Run with QUENDERIN_RUNTIME=prism swift test --filter PrismNativeCapabilityTests.
/// CI also executes a small C probe against the actual Mac framework before resolution.
final class PrismNativeCapabilityTests: XCTestCase {
    func testPinnedNativeTypesEnableManualBonsaiWithoutChangingDefaults() throws {
        #if canImport(llama) && QUENDERIN_PRISM_LLAMA
        for (raw, name, bytes) in [(UInt32(142), "pq2_0", 34), (UInt32(143), "ptq1_0", 28)] {
            let type = ggml_type(rawValue: raw)
            XCTAssertEqual(String(cString: ggml_type_name(type)), name)
            XCTAssertEqual(ggml_blck_size(type), 128)
            XCTAssertEqual(ggml_type_size(type), bytes)
        }
        XCTAssertTrue(ModelRuntimeSupport.supportsBonsai)
        let bonsai = try XCTUnwrap(ModelCatalog.entry(id: "bonsai2-27b"))
        XCTAssertTrue(ModelRuntimeSupport.supports(bonsai))
        XCTAssertEqual(MemoryFitness.check(model: bonsai, totalGB: 16, freeGB: 16).requiredMemoryGB, 9.1, accuracy: 1e-9)
        XCTAssertEqual(MemoryFitness.defaultBudgetHard, 0.85)
        XCTAssertFalse(IPhoneModelSelector.defaultPreferenceIDs.contains(bonsai.id))
        XCTAssertEqual(ModelCatalog.smallest.id, "llama32-1b-q2")
        #else
        if ProcessInfo.processInfo.environment["QUENDERIN_RUNTIME"] == "prism" {
            XCTFail("Prism profile did not compile/link the native capability path")
        } else {
            throw XCTSkip("Positive capability check requires the verified Prism runtime")
        }
        #endif
    }
}
