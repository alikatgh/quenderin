import XCTest
import CryptoKit
@testable import QuenderinKit

final class ImageModelsTests: XCTestCase {
    private let data = Data([1, 2, 3, 4])
    private func model() -> ImageModel {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImageModel(id: "fixture-image", label: "Fixture", modelKind: 1, license: "Fixture",
                          licenseUrl: "https://example.com/terms", requiresPublisherAccess: true,
                          defaults: ImageModelDefaults(width: 512, height: 512, steps: 1, cfg: 1, flowShift: 1),
                          components: ["diffusion", "text_encoder", "vae"].map {
            ImageModelComponent(role: $0, repo: "fixture/model", revision: String(repeating: "a", count: 40),
                                filename: "\($0).bin", localFilename: "\($0).bin", bytes: Int64(data.count),
                                sha256: sha, access: "publisher-gated")
        })
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quenderin-image-fixture-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var ample: ImageResourceBudget { ImageResourceBudget(availableMemoryBytes: 64 * 1_073_741_824, freeDiskBytes: 100 * 1_073_741_824) }

    func testBundledCatalogContainsCompleteBoundedPackages() throws {
        let catalog = try ImageModelCatalog.bundled()
        XCTAssertEqual(Set(catalog.models.map(\.id)), Set(["flux3-image-klein", "moss-image-base", "moss-image-sft"]))
        for model in catalog.models { try model.validate(); XCTAssertGreaterThan(model.downloadBytes, 10_000_000_000) }
        let phone = ImageResourceBudget(availableMemoryBytes: 8 * 1_073_741_824, freeDiskBytes: 100 * 1_073_741_824)
        XCTAssertNotNil(phone.blockReason(for: catalog.models[0], installing: true))
        let noDisk = ImageResourceBudget(availableMemoryBytes: ample.availableMemoryBytes, freeDiskBytes: catalog.models[0].downloadBytes)
        XCTAssertNotNil(noDisk.blockReason(for: catalog.models[0], installing: true), "The entire package plus output reserve must fit")
    }

    func testImportsVerifyAllComponentsAndPreserveOriginals() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let fixture = model()
        let sources = try fixture.components.map { component -> URL in
            let source = originals.appendingPathComponent(component.filename)
            try data.write(to: source, options: .withoutOverwriting)
            return source
        }
        let installer = ImageModelInstaller(directory: root.appendingPathComponent("installed"))
        let installed = try await installer.install(fixture, budget: ample, imported: sources, publisherTermsAccepted: true) { _ in }
        try ImageModelInstaller.verify(fixture, in: installed)
        for source in sources { XCTAssertEqual(try Data(contentsOf: source), data) }
        try Data([9, 9, 9, 9]).write(to: installed.appendingPathComponent(fixture.components[1].localFilename))
        XCTAssertThrowsError(try ImageModelInstaller.verify(fixture, in: installed), "Same length alone cannot establish readiness")
    }

    func testMissingComponentsAndRejectedPublisherTermsDoNotStartInstallation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = model()
        XCTAssertThrowsError(try ImageModelInstaller.verify(fixture, in: root))
        let installer = ImageModelInstaller(directory: root.appendingPathComponent("installed"))
        do {
            _ = try await installer.install(fixture, budget: ample) { _ in }
            XCTFail("Gated model must require explicit publisher acceptance and files")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("installed").path)) }
    }

    func testCancelledVerificationStopsBeforeNativeInference() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = model()
        for component in fixture.components { try data.write(to: root.appendingPathComponent(component.localFilename)) }
        XCTAssertThrowsError(try ImageModelInstaller.verify(fixture, in: root, cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNewDirectoryURLFlagsAreAllowedAndActualSymlinksAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = model()
        let fresh = root.appendingPathComponent("not-created", isDirectory: true)
        XCTAssertEqual(try ImageModelInstaller.remainingDownloadBytes(fixture, in: fresh), fixture.downloadBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ImageModelInstaller.remainingDownloadBytes(fixture, in: link))
    }

    func testRetryBudgetsOnlyVerifiedMissingComponentsAndPreservesCorruptFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = model()
        let base = root.appendingPathComponent("installed")
        let target = base.appendingPathComponent(fixture.id)
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let retained = target.appendingPathComponent(fixture.components[0].localFilename)
        try data.write(to: retained, options: .withoutOverwriting)
        let sources = try fixture.components.map { component -> URL in
            let source = originals.appendingPathComponent(component.filename)
            try data.write(to: source, options: .withoutOverwriting)
            return source
        }
        let remaining = fixture.downloadBytes - fixture.components[0].bytes
        let retryBudget = ImageResourceBudget(availableMemoryBytes: ample.availableMemoryBytes,
                                             freeDiskBytes: 1_073_741_824 + remaining)
        XCTAssertNotNil(retryBudget.blockReason(for: fixture, installing: true), "The old full-package gate rejects this valid retry")
        XCTAssertEqual(try ImageModelInstaller.remainingDownloadBytes(fixture, in: target), remaining)
        let installer = ImageModelInstaller(directory: base)
        let installed = try await installer.install(fixture, budget: retryBudget, imported: sources, publisherTermsAccepted: true) { _ in }
        try ImageModelInstaller.verify(fixture, in: installed)
        let corrupt = Data([9, 9, 9, 9])
        try corrupt.write(to: retained)
        XCTAssertThrowsError(try ImageModelInstaller.remainingDownloadBytes(fixture, in: target), "Same-size corruption cannot reduce the reservation")
        do {
            _ = try await installer.install(fixture, budget: retryBudget, imported: sources, publisherTermsAccepted: true) { _ in }
            XCTFail("A corrupt retained component must be reported, never replaced")
        } catch {
            XCTAssertEqual(try Data(contentsOf: retained), corrupt)
            for source in sources { XCTAssertEqual(try Data(contentsOf: source), data) }
        }
    }

    @MainActor
    func testControllerUsesInjectedEngineAndKeepsResultForExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = model()
        let models = root.appendingPathComponent("models")
        let folder = models.appendingPathComponent(fixture.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for component in fixture.components { try data.write(to: folder.appendingPathComponent(component.localFilename)) }
        let budget = ample
        let controller = ImageGenerationController(catalog: ImageModelCatalog(version: 1, models: [fixture]),
            engine: FixtureImageEngine(), directory: models, budget: { budget })
        controller.publisherTermsAccepted = true
        controller.prompt = "A simple scene for a synthetic fixture."
        controller.generate()
        for _ in 0..<100 where controller.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.busy)
        XCTAssertNil(controller.failure)
        XCTAssertNotNil(controller.output)
        XCTAssertEqual(controller.status, "Image created locally.")
    }
}

private struct FixtureImageEngine: ImageGenerationEngine {
    let available = true
    func generate(_ request: ImageGenerationRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress(0.5)
        try Task.checkCancellation()
        try Data([137, 80, 78, 71, 13, 10, 26, 10]).write(to: request.output, options: .withoutOverwriting)
        return request.output
    }
    func cancel() {}
}
