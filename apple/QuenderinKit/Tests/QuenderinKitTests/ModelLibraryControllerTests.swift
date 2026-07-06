import XCTest
@testable import QuenderinKit

/// Q-271: the Models-library download path is the SECOND live download site (after onboarding). It
/// used to skip the DownloadPolicy entirely, so an already-onboarded user could burn multi-GB of
/// cellular data adding a model. The gate is synchronous (it runs before the download Task spawns),
/// so the blocked case is fully deterministic — no network, no spin-wait.
final class ModelLibraryControllerTests: XCTestCase {

    private func stubEntry() -> ModelEntry {
        // Unique filename per test so the shared DownloadCoordinator's file-claim can't collide.
        ModelEntry(
            id: "lib-\(UUID().uuidString)", label: "Stub", filename: "lib-\(UUID().uuidString).gguf",
            ramGB: 1, sizeLabel: "100 B", paramsBillions: 0.001, quantization: "Q2_K",
            urlString: "https://example.com/stub.gguf", sha256: nil
        )
    }

    private func freshDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lib-\(UUID().uuidString)")
    }

    @MainActor
    func testLibraryDownloadBlocksCellularUnderWifiOnly() {
        let entry = stubEntry()
        let controller = ModelLibraryController(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "network must NOT be touched")),
            modelsDir: freshDir(),
            networkStatus: { .cellular },
            downloadPolicy: { .wifiOnly }
        )
        controller.download(entry)

        // Synchronous gate → the blocked state is already set, carrying the policy reason (proving the
        // download Task — which would have failed transport — never started).
        guard case let .failed(reason) = controller.state(of: entry) else {
            return XCTFail("expected .failed(reason) for a cellular-blocked library download, got \(controller.state(of: entry))")
        }
        XCTAssertEqual(reason, DownloadPolicy.wifiOnly.reason(for: .cellular))
    }

    @MainActor
    func testLibraryDownloadProceedsWhenPolicyPermits() {
        let entry = stubEntry()
        let controller = ModelLibraryController(
            downloader: MockModelDownloader(behavior: .failTransport(reason: "reached the network")),
            modelsDir: freshDir(),
            networkStatus: { .cellular },
            downloadPolicy: { .wifiOrCellular }     // user opted into cellular → don't block
        )
        controller.download(entry)

        // Not gated: `download()` synchronously moves to .downloading before spawning the Task. We
        // don't await the Task (weak-self; it unwinds when the controller deallocates) — proving the
        // gate let it through is the assertion.
        XCTAssertEqual(controller.state(of: entry), .downloading(0))
    }
}
