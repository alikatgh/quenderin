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

    func testSmallerPinnedArtifactsKeepIndependentRuntimeAndMemoryGates() throws {
        let expected: [(String, Int64, String, String, Double)] = [
            ("bonsai2-2b", 429_183_456, "683f7be2629342a50987627b40881e54761a2430", "36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa", 1.95),
            ("bonsai2-4b", 949_549_920, "8d6557168168f91ea6697a4a49ed2ef622b53adb", "56711263ec9a9ffeaa74a3a0e58dece8127cf9268404746c721113ca76994d60", 3.25),
            ("bonsai2-9b", 1_997_486_976, "5b2abb02362efbed46bbe204014b02837778b2c2", "3561df7ac7d26a71ffa991ac2db740b10841c3a350aa2676ccd3ff5d428b4e8b", 5.2),
        ]
        for (id, bytes, revision, sha, required) in expected {
            let model = try XCTUnwrap(ModelCatalog.entry(id: id))
            XCTAssertEqual(model.sha256, sha)
            XCTAssertEqual(model.downloadBytes, bytes)
            XCTAssertEqual(DiskSpace.estimatedDownloadBytes(for: model), bytes)
            XCTAssertTrue(model.urlString.contains("/resolve/\(revision)/\(model.filename)?download=true"))
            XCTAssertTrue(model.label.contains("(Experimental)"))
            XCTAssertTrue(ModelRuntimeSupport.requiresPrism(model))
            XCTAssertFalse(IPhoneModelSelector.defaultPreferenceIDs.contains(id))
            XCTAssertFalse(MemoryFitness.check(model: model, totalGB: 64, freeGB: 64, prismRuntimeAvailable: false).canLoad)
            XCTAssertEqual(MemoryFitness.check(model: model, totalGB: 64, freeGB: 64, prismRuntimeAvailable: true).requiredMemoryGB, required, accuracy: 1e-9)
            XCTAssertFalse(IPhoneModelSelector.fitness(of: model, for: phone(budget: required), prismRuntimeAvailable: true).canLoad)
            XCTAssertTrue(IPhoneModelSelector.fitness(of: model, for: phone(budget: required * 2), prismRuntimeAvailable: true).canLoad)
        }
        XCTAssertEqual(ModelRuntimeSupport.bonsaiMaxContextTokens, 4096)
        for ram in [1.0, 2.0, 4.0, 8.0, 16.0, 64.0] {
            XCTAssertFalse(ModelRecommender.recommendedModelID(forTotalRAMGB: ram).contains("bonsai"))
            XCTAssertFalse(ModelRecommender.bestInstallableModel(forTotalRAMGB: ram).id.contains("bonsai"))
        }
    }

    func testSmallBonsaiIdentityWithoutPinnedIntegrityKeepsImportedFloor() throws {
        let pinned = try XCTUnwrap(ModelCatalog.entry(id: "bonsai2-2b"))
        let imported = ModelEntry(id: pinned.id, label: pinned.label, filename: pinned.filename,
            ramGB: 0.1, sizeLabel: pinned.sizeLabel, paramsBillions: pinned.paramsBillions,
            quantization: pinned.quantization, urlString: pinned.urlString, sha256: nil,
            downloadBytes: pinned.downloadBytes)
        XCTAssertEqual(ModelRuntimeSupport.memoryFootprintGB(imported), 7, accuracy: 1e-9)
        XCTAssertEqual(MemoryFitness.check(model: imported, totalGB: 64, freeGB: 64, prismRuntimeAvailable: true).requiredMemoryGB, 9.1, accuracy: 1e-9)
        let understated = ModelEntry(id: pinned.id, label: pinned.label, filename: pinned.filename,
            ramGB: 0.1, sizeLabel: pinned.sizeLabel, paramsBillions: pinned.paramsBillions,
            quantization: pinned.quantization, urlString: pinned.urlString, sha256: pinned.sha256,
            downloadBytes: pinned.downloadBytes)
        XCTAssertEqual(ModelRuntimeSupport.memoryFootprintGB(understated), 1.5, accuracy: 1e-9)
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
            BackgroundModelDownloader(store: DownloadStore(fileURL: directory.appendingPathComponent("downloads.json")))]
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
