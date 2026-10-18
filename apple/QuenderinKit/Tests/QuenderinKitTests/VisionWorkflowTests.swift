import XCTest
@testable import QuenderinKit

private actor VisionWorkflowCounter {
    var acquisitions = 0, resumptions = 0, answers = 0
    func acquired() { acquisitions += 1 }
    func resumed() { resumptions += 1 }
    func answered() { answers += 1 }
    func counts() -> [Int] { [acquisitions, resumptions, answers] }
}
private struct VisionWorkflowFixtureEngine: VisionInferencePort {
    let counter: VisionWorkflowCounter
    var visionAvailable: Bool { true }
    func answer(model: VisionModelDescriptor, modelURL: URL, projectorURL: URL, imageURL: URL, prompt: String, availableMemoryBytes: Int64) async throws -> String { await counter.answered(); return "Synthetic fixture answer" }
    func cancel() {}
    func close() async {}
}

final class VisionWorkflowTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/hj0AAAAASUVORK5CYII=")!
    func testCompletePresetMemoryAndDiskFloors() throws {
        XCTAssertEqual(VisionModels.all.map(\.minimumMemoryBytes), [8, 32, 96].map { Int64($0) * 1_073_741_824 })
        for model in VisionModels.all {
            XCTAssertEqual(Set(model.artifacts.map(\.role)), ["model", "projector"])
            XCTAssertThrowsError(try VisionModelInstaller.checkResources(model, memory: model.minimumMemoryBytes - 1, disk: .max))
            XCTAssertThrowsError(try VisionModelInstaller.checkResources(model, memory: model.minimumMemoryBytes, disk: 67_108_863))
            XCTAssertNoThrow(try VisionModelInstaller.checkResources(model, memory: model.minimumMemoryBytes, disk: 67_108_864))
        }
    }
    func testOnlySelectedStillCopiedAndRejectedStagingRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png"); try png.write(to: original)
        let copied = try VisionSelectedImage.copy(original, into: root.appendingPathComponent("selected"))
        XCTAssertEqual(try Data(contentsOf: copied), png); XCTAssertEqual(try Data(contentsOf: original), png)
        var wide = png; wide[16] = 0; wide[17] = 0; wide[18] = 0x20; wide[19] = 0
        let invalid = root.appendingPathComponent("wide.png"); try wide.write(to: invalid)
        XCTAssertThrowsError(try VisionSelectedImage.copy(invalid, into: root.appendingPathComponent("rejected")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rejected").path), [])
    }
    @MainActor func testVerificationFailureResumesTextAndRetainsQuestionAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png"); try png.write(to: original)
        let counter = VisionWorkflowCounter()
        let controller = VisionController(installer: VisionModelInstaller(directory: root.appendingPathComponent("models")), engine: VisionWorkflowFixtureEngine(counter: counter), budget: { ImageResourceBudget(availableMemoryBytes: 0, freeDiskBytes: .max) }, selectedImageDirectory: root, suspendForSpecialist: {
            await counter.acquired(); return SpecialistInferenceLease { await counter.resumed() }
        })
        controller.chooseImage(original)
        for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(controller.imageURL); controller.prompt = "Synthetic question"; controller.ask()
        for _ in 0..<200 where controller.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(controller.busy); XCTAssertNotNil(controller.failure); XCTAssertEqual(controller.prompt, "Synthetic question"); XCTAssertNotNil(controller.imageURL)
        let counts = await counter.counts(); XCTAssertEqual(counts, [1, 1, 0]); XCTAssertEqual(try Data(contentsOf: original), png)
    }
}
