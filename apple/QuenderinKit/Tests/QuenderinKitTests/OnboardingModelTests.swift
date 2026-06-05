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
}
