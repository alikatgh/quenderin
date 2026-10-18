import XCTest
@testable import QuenderinKit

final class BeamRuntimeTests: XCTestCase {
    func testCompleteManifestAndActualMetadataCapabilityBoundary() throws {
        let model = try XCTUnwrap(ModelCatalog.entry(id: "beam-1.0-501b-a23b-ud-iq2-xxs"))
        XCTAssertEqual(try ModelArtifactSet.validate(model).count, 4)
        XCTAssertEqual(model.downloadBytes, 133885310500)
        let metadata = GGUFModelMetadata(architecture: "beam", splitCount: 4)
        XCTAssertThrowsError(try metadata.validateForLoad(model, weeklyTextRuntimeAvailable: true, beamRuntimeAvailable: false))
        XCTAssertNoThrow(try metadata.validateForLoad(model, weeklyTextRuntimeAvailable: true, beamRuntimeAvailable: true))
        XCTAssertThrowsError(try GGUFModelMetadata(architecture: "beam", splitCount: 1)
            .validateForLoad(model, weeklyTextRuntimeAvailable: true, beamRuntimeAvailable: true))
        XCTAssertFalse(MemoryFitness.check(model: model, totalGB: 159, freeGB: 159,
            prismRuntimeAvailable: true, beamRuntimeAvailable: true).canLoad)
        XCTAssertTrue(MemoryFitness.check(model: model, totalGB: 256, freeGB: 256,
            prismRuntimeAvailable: true, beamRuntimeAvailable: true).canLoad)
        XCTAssertFalse(MemoryFitness.check(model: model, totalGB: 512, freeGB: 512,
            prismRuntimeAvailable: true, beamRuntimeAvailable: false).canLoad)
    }
    func testOfficialMinimalPromptAndRestoredFinalHistoryPolicy() {
        let prompt = BeamChatPrompt.build(system: "Answer concisely.", history: [.init(role: .user, text: "Hello")])
        XCTAssertEqual(prompt, "<|start|>system<|message|>You are Beam, an AI assistant trained by Reflection.\n\nReasoning effort: 8\n\n# Valid channels: analysis, final. Channel must be included for every message.<|end|><|start|>developer<|message|># Instructions\n\nAnswer concisely.<|end|><|start|>user<|message|>Hello<|end|><|start|>assistant")
        XCTAssertTrue(BeamChatPrompt.allowMissingThinking)
        XCTAssertTrue(BeamChatPrompt.build(system: "", history: [.init(role: .assistant, text: "Restored")])
            .contains("<|channel|>analysis<|message|><|end|><|start|>assistant<|channel|>final<|message|>Restored<|return|>"))
    }
    func testEverySplitHidesReasoningAndWireHeaders() {
        let wire = "<|channel|>analysis<|message|>private<|end|><|start|>assistant<|channel|>final<|message|>Hello 🌲<|return|>leak"
        for offset in 0...wire.count {
            let split = wire.index(wire.startIndex, offsetBy: offset)
            var filter = BeamFinalChannelFilter()
            XCTAssertEqual(filter.feed(String(wire[..<split])) + filter.feed(String(wire[split...])) + filter.finish(), "Hello 🌲")
        }
        for wire in [String(repeating: "x", count: 2048), "<|channel|>final to=tool<|message|>leak", "<|channel|>analysis<|message|>hidden"] {
            var filter = BeamFinalChannelFilter()
            XCTAssertEqual(filter.feed(wire) + filter.finish(), "")
        }
    }
}
