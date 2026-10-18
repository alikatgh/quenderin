import Foundation
import XCTest
@testable import QuenderinKit

final class UnavailableModelWorkflowTests: XCTestCase {
    func testUnavailableNamesCannotAcquireChatSupportOrDownloadPermission() {
        for name in ["Beam-1.0-501B-A23B", "Hy-Memory-30B-A3B", "Nemotron-3.5-Super-VL-120B", "Step-5-Preview", "Granite-Switch-4.1", "Nemotron-3.5-Bolt-E4B", "Nemotron-3.5-Unknown", "Bolt-E4B", "Super-VL-120B", "Beam1.0-501B"] {
            for field in 0..<4 {
                let model = ModelEntry(id: field == 0 ? name : "custom", label: field == 1 ? name : "Custom",
                    filename: field == 2 ? name + ".gguf" : "custom.gguf", ramGB: 0.1, sizeLabel: "small",
                    paramsBillions: 1, quantization: "Q4_K_M", urlString: field == 3 ? "https://example.invalid/\(name).gguf" : "https://example.invalid/custom.gguf", sha256: nil)
                XCTAssertFalse(ModelRuntimeSupport.supports(model), name)
                XCTAssertNotNil(ModelRuntimeSupport.unsupportedWorkflowReason(for: model))
                XCTAssertFalse(MemoryFitness.check(model: model, totalGB: 1024, freeGB: 1024,
                    prismRuntimeAvailable: true, museRuntimeAvailable: true, weeklyTextRuntimeAvailable: true).canLoad)
            }
            let url = URL(string: "https://example.invalid/\(name).gguf")!
            XCTAssertNotNil(ModelRuntimeSupport.blockedDownloadReason(from: url, to: URL(fileURLWithPath: "/unused/model.gguf")))
        }
    }

    func testOlderFamiliesAndPinnedWeeklyIdentitiesAreNotBlockedAsUnavailableWorkflows() {
        let encoded = ModelEntry(id: "custom", label: "Custom", filename: "custom.gguf", ramGB: 1,
            sizeLabel: "small", paramsBillions: 1, quantization: "Q4_K_M",
            urlString: "https://example.invalid/NVIDIA%2DNemotron%2D3.5%2DBolt%2D74B%2DA9B.gguf", sha256: nil)
        XCTAssertTrue(ModelRuntimeSupport.requiresWeeklyTextRuntime(encoded))
        XCTAssertNil(ModelRuntimeSupport.unsupportedWorkflowReason(for: encoded))
        for name in ["Granite-4.0", "Hunyuan-3.0", "Nemotron-3-Super", "Step-3.5-Flash"] {
            XCTAssertNil(ModelRuntimeSupport.unsupportedWorkflowReason(identifiers: [name]))
        }
        for model in ModelCatalog.models where model.id.hasPrefix("jais3") || model.id.hasPrefix("nemotron35") || model.id.hasPrefix("minicpm-v47") || model.id == "lfm25-24b-a2b" {
            XCTAssertNil(ModelRuntimeSupport.unsupportedWorkflowReason(for: model), model.id)
        }
    }

    func testEncodedWeeklyDownloadIdentitiesUseTheSameCapabilityGateAsDescriptors() {
        for name in ["NVIDIA%2DNemotron%2D3.5%2DBolt%2D74B%2DA9B", "Jais%2D3%2D0.9B"] {
            for field in 0..<3 {
                let url = URL(string: field == 0 ? "https://example.invalid/\(name).gguf" : "https://example.invalid/custom.gguf")!
                let destination = URL(fileURLWithPath: field == 1 ? "/unused/\(name).gguf" : "/unused/custom.gguf")
                let modelID = field == 2 ? name : "custom"
                let model = ModelEntry(id: modelID, label: "Custom", filename: destination.lastPathComponent,
                    ramGB: 1, sizeLabel: "small", paramsBillions: 1, quantization: "Q4_K_M", urlString: url.absoluteString, sha256: nil)
                XCTAssertTrue(ModelRuntimeSupport.requiresWeeklyTextRuntime(model))
                XCTAssertEqual(ModelRuntimeSupport.blockedDownloadReason(from: url, to: destination, modelID: modelID,
                    weeklyTextRuntimeAvailable: false), ModelRuntimeSupport.weeklyTextUnavailableMessage)
                XCTAssertNil(ModelRuntimeSupport.blockedDownloadReason(from: url, to: destination, modelID: modelID,
                    weeklyTextRuntimeAvailable: true))
            }
        }
    }
}
