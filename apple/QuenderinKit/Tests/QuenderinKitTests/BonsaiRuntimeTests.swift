import XCTest
@testable import QuenderinKit

final class BonsaiRuntimeTests: XCTestCase {
    private var bonsai: ModelEntry { ModelCatalog.entry(id: "bonsai2-27b")! }

    private func phone(budget: Double) -> IOSDeviceProfile {
        IOSDeviceProfile(deviceName: "Test", identifier: "test", chip: .a18Pro,
                         totalRAMGB: 16, appMemoryBudgetGB: budget, freeDiskGB: 64, isKnownDevice: false)
    }

    func testPinnedArtifactAndCustomQuantization() {
        XCTAssertEqual(bonsai.filename, "Ternary-Bonsai-2-27B-PTQ1_0.gguf")
        XCTAssertEqual(bonsai.paramsBillions, 27.36)
        XCTAssertEqual(bonsai.sha256, "53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3")
        XCTAssertTrue(bonsai.urlString.contains("/b072e1d3b35a0a630cece372c2127528e0994386/"))
        XCTAssertEqual(Quantization.info(id: "PTQ1_0")?.bitsPerWeight, 1.75)
        XCTAssertEqual(Quantization.info(id: "PQ2_0")?.bitsPerWeight, 2.13)
        XCTAssertEqual(DiskSpace.estimatedDownloadBytes(for: bonsai), 5_946_648_928)
        XCTAssertEqual(IPhoneModelSelector.estimatedDownloadGB(bonsai), 5.946648928, accuracy: 1e-9)
        XCTAssertEqual(ModelCatalog.smallest.id, "llama32-1b-q2")
        XCTAssertFalse(IPhoneModelSelector.defaultPreferenceIDs.contains(bonsai.id))
    }

    func testRuntimeAndMemoryAreIndependentGates() {
        let unavailable = MemoryFitness.check(model: bonsai, totalGB: 64, freeGB: 64, prismRuntimeAvailable: false)
        XCTAssertFalse(unavailable.canLoad)
        XCTAssertEqual(unavailable.message, ModelRuntimeSupport.unavailableMessage)
        XCTAssertFalse(MemoryFitness.check(model: bonsai, totalGB: 8, freeGB: 8, prismRuntimeAvailable: true).canLoad)
        XCTAssertTrue(MemoryFitness.check(model: bonsai, totalGB: 16, freeGB: 16, prismRuntimeAvailable: true).canLoad)
        let low = IPhoneModelSelector.fitness(of: bonsai, for: phone(budget: 7), prismRuntimeAvailable: true)
        XCTAssertFalse(low.canLoad, "The 5.95 GB file is not the runtime footprint")
        XCTAssertEqual(low.requiredMemoryGB, 9.1, accuracy: 1e-9)
        XCTAssertTrue(IPhoneModelSelector.fitness(of: bonsai, for: phone(budget: 12), prismRuntimeAvailable: true).canLoad)
        XCTAssertFalse(IPhoneModelSelector.fitness(of: bonsai, for: phone(budget: 20), prismRuntimeAvailable: false).canLoad)
    }

    func testSideloadedIdentityAndCustomQuantCannotBypassRuntimeGate() {
        let quantOnly = ModelEntry(id: "hf:unknown", label: "Custom", filename: "custom.gguf", ramGB: 1,
                                   sizeLabel: "1 GB", paramsBillions: 1, quantization: "pq2_0",
                                   urlString: "https://example.com/custom.gguf", sha256: nil)
        let nameOnly = ModelEntry(id: "hf:bonsai-copy", label: "Custom", filename: "custom.gguf", ramGB: 1,
                                  sizeLabel: "1 GB", paramsBillions: 1, quantization: "Q4_K_M",
                                  urlString: "https://example.com/custom.gguf", sha256: nil)
        XCTAssertTrue(ModelRuntimeSupport.requiresPrism(quantOnly))
        XCTAssertTrue(ModelRuntimeSupport.requiresPrism(nameOnly))
        XCTAssertFalse(MemoryFitness.check(model: quantOnly, totalGB: 64, freeGB: 64, prismRuntimeAvailable: false).canLoad)
        XCTAssertEqual(MemoryFitness.check(model: nameOnly, totalGB: 64, freeGB: 64, prismRuntimeAvailable: true).requiredMemoryGB, 9.1, accuracy: 1e-9)
    }

    func testStockEngineRejectsBeforeMissingFileIO() async throws {
        try XCTSkipIf(ModelRuntimeSupport.supportsBonsai, "Requires a stock runtime build")
        do {
            try await LlamaEngine(deviceBudgetGB: 64).load(model: bonsai, at: URL(fileURLWithPath: "/missing-bonsai-test.gguf"))
            XCTFail("Unsupported model must fail before file checks")
        } catch InferenceError.loadFailed(let reason) {
            XCTAssertEqual(reason, ModelRuntimeSupport.unavailableMessage)
        } catch {
            XCTFail("Expected runtime rejection before missing-file check, got \(error)")
        }
    }

    func testStockDownloaderRejectsBeforeCreatingDestination() async throws {
        try XCTSkipIf(ModelRuntimeSupport.supportsBonsai, "Requires a stock runtime build")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bonsai-rejected-\(UUID().uuidString)")
        let destination = directory.appendingPathComponent(bonsai.filename)
        let downloaders: [any ModelDownloader] = [URLSessionModelDownloader(), ParallelRangeDownloader(),
            BackgroundModelDownloader(store: DownloadStore())]
        for downloader in downloaders {
            do {
                for try await _ in downloader.download(from: bonsai.downloadURL!, to: destination) {}
                XCTFail("Unsupported download must fail")
            } catch DownloadError.transport(let reason) {
                XCTAssertEqual(reason, ModelRuntimeSupport.unavailableMessage)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testStockOnboardingRejectsBeforeDownloadAndKeepsWorkingModel() async throws {
        try XCTSkipIf(ModelRuntimeSupport.supportsBonsai, "Requires a stock runtime build")
        let engine = MockInferenceEngine()
        try await engine.load(model: ModelCatalog.smallest, at: URL(fileURLWithPath: "/unused"))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bonsai-onboarding-rejected-\(UUID().uuidString)")
        let onboarding = OnboardingModel(downloader: MockModelDownloader(behavior: .failTransport(reason: "download called")),
                                         engine: engine, modelsDir: directory, availableDiskBytes: { _ in .max })
        await onboarding.install(bonsai)
        guard case .failed(let reason) = onboarding.phase else { return XCTFail("Expected runtime rejection") }
        XCTAssertEqual(reason, ModelRuntimeSupport.unavailableMessage)
        let loadedID = await engine.loadedModelID()
        XCTAssertEqual(loadedID, ModelCatalog.smallest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
