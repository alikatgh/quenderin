import XCTest
@testable import QuenderinKit

@MainActor
final class OnboardingModelTests: XCTestCase {

    private func freshModelsDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-onb-\(UUID().uuidString)", isDirectory: true)
    }

    func testStartProbesAndRecommends() async {
        let dir = freshModelsDir()
        let model = OnboardingModel(downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir)

        await model.start()

        guard case let .recommended(entry, hardware, _) = model.phase else {
            return XCTFail("expected .recommended, got \(model.phase)")
        }
        XCTAssertNotNil(ModelCatalog.entry(id: entry.id))
        XCTAssertGreaterThan(hardware.totalRAMGB, 0)
    }

    func testInstallHappyPathReachesReady() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = OnboardingModel(downloader: MockModelDownloader(), engine: MockInferenceEngine(), modelsDir: dir)
        let entry = ModelCatalog.smallest

        await model.install(entry)

        guard case let .ready(readyEntry) = model.phase else {
            return XCTFail("expected .ready, got \(model.phase)")
        }
        XCTAssertEqual(readyEntry.id, entry.id)
        // The downloader wrote the file to the models dir.
        let expected = dir.appendingPathComponent(entry.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testInstallSkipsDownloadWhenFileExists() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = ModelCatalog.smallest

        // Pre-create the model file so install should go straight to loading.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(entry.filename).path, contents: Data())

        // A downloader that would FAIL if called — proves we skipped it.
        let model = OnboardingModel(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "should not be called")),
            engine: MockInferenceEngine(),
            modelsDir: dir
        )
        await model.install(entry)

        guard case .ready = model.phase else {
            return XCTFail("expected .ready (download skipped), got \(model.phase)")
        }
    }

    func testInstallSurfacesDownloadFailure() async {
        let dir = freshModelsDir()
        let model = OnboardingModel(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "offline")),
            engine: MockInferenceEngine(),
            modelsDir: dir
        )

        await model.install(ModelCatalog.smallest)

        guard case let .failed(message) = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("offline"), "message should explain the cause: \(message)")
    }

    func testStartUsesIPhoneSelectorWhenProfileInjected() async {
        let dir = freshModelsDir()
        let device = IOSDeviceProfile(
            deviceName: "iPhone 15 Pro", identifier: "iPhone16,1", chip: .a17Pro, totalRAMGB: 8,
            appMemoryBudgetGB: AppleDeviceDatabase.estimatedAppMemoryBudgetGB(totalRAMGB: 8),
            freeDiskGB: 128, isKnownDevice: true
        )
        let model = OnboardingModel(
            downloader: MockModelDownloader(), engine: MockInferenceEngine(),
            modelsDir: dir, deviceProfile: device
        )

        await model.start()

        guard case let .recommended(entry, _, fitness) = model.phase else {
            return XCTFail("expected .recommended, got \(model.phase)")
        }
        // The jetsam-aware selector picks the safe 4B on an 8 GB iPhone, not a 7B/14B over-pick.
        XCTAssertEqual(entry.id, "qwen3-4b")
        XCTAssertEqual(model.selection?.model.id, "qwen3-4b")
        XCTAssertTrue(fitness.message.contains("iPhone 15 Pro"), "fitness carries the rationale")
        XCTAssertFalse(model.selection?.alternatives.isEmpty ?? true, "alternatives are surfaced")
    }

    func testInstallSurfacesLoadFailure() async {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mock download succeeds, but the real LlamaEngine (no llama.cpp linked)
        // fails to load → onboarding must surface a clean failure, not crash.
        let model = OnboardingModel(
            downloader: MockModelDownloader(),
            engine: LlamaEngine(),
            modelsDir: dir
        )

        await model.install(ModelCatalog.smallest)

        guard case .failed = model.phase else {
            return XCTFail("expected .failed from LlamaEngine load, got \(model.phase)")
        }
    }

    /// A failed model SWITCH must restore the previously-working model, not leave the engine empty (H1).
    func testFailedSwitchRestoresPreviousModel() async throws {
        let dir = freshModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelA = ModelCatalog.smallest
        let modelB = try XCTUnwrap(ModelCatalog.models.first { $0.id != modelA.id })

        let engine = FailOnLoadEngine(failingID: modelB.id)
        let onboarding = OnboardingModel(downloader: MockModelDownloader(), engine: engine, modelsDir: dir)

        await onboarding.install(modelA)                      // first model loads fine
        guard case .ready(let readyA) = onboarding.phase, readyA.id == modelA.id else {
            return XCTFail("expected .ready(modelA), got \(onboarding.phase)")
        }

        await onboarding.install(modelB)                      // switch to B — B fails to load
        guard case .ready(let readyB) = onboarding.phase else {
            return XCTFail("a failed switch must restore the previous model, got \(onboarding.phase)")
        }
        XCTAssertEqual(readyB.id, modelA.id)                  // restored to A — session not bricked
        let loaded = await engine.loadedModelID()
        XCTAssertEqual(loaded, modelA.id)                     // engine actually re-loaded A
    }
}

/// Test engine that loads any model except `failingID`, which throws — exercises the failed-switch
/// recovery path without a real (multi-GB) model.
private actor FailOnLoadEngine: InferenceEngine {
    let failingID: String
    private var loaded: String?
    init(failingID: String) { self.failingID = failingID }
    func loadedModelID() async -> String? { loaded }
    func load(model: ModelEntry, at fileURL: URL) async throws {
        if model.id == failingID { throw InferenceError.loadFailed(reason: "test: too big to load") }
        loaded = model.id
    }
    func unload() async { loaded = nil }
    func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
