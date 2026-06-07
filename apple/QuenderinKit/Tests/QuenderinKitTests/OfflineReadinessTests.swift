import XCTest
@testable import QuenderinKit

final class OfflineReadinessTests: XCTestCase {

    private func model(_ id: String) -> ModelEntry { ModelCatalog.entry(id: id)! }

    func testNotDownloaded() {
        let readiness = OfflineReadinessChecker.evaluate(model: ModelCatalog.smallest, fileExists: false, fileSizeBytes: 0)
        XCTAssertFalse(readiness.isReadyForOffline)
        XCTAssertEqual(readiness.status, .notDownloaded)
    }

    func testIncompletePartialIsNotReady() {
        // ~4.5 GB expected, only 1 GB on disk → not safe to go offline.
        let readiness = OfflineReadinessChecker.evaluate(model: model("llama3-8b"), fileExists: true, fileSizeBytes: 1_000_000_000)
        XCTAssertFalse(readiness.isReadyForOffline)
        guard case .incomplete = readiness.status else {
            return XCTFail("expected .incomplete, got \(readiness.status)")
        }
    }

    func testCompleteIsReadyWithReassuringMessage() {
        // 1B Q2_K ≈ 0.33 GB; a 0.4 GB file is complete.
        let readiness = OfflineReadinessChecker.evaluate(model: model("llama32-1b-q2"), fileExists: true, fileSizeBytes: 400_000_000)
        XCTAssertTrue(readiness.isReadyForOffline)
        XCTAssertTrue(readiness.message.contains("✅"))
    }

    func testLiveCheckReadsFileSizeFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qkit-rdy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = ModelCatalog.smallest
        // A tiny partial file (1 KB) — proves the live path finds + sizes it,
        // and correctly reports "incomplete" rather than "not downloaded".
        FileManager.default.createFile(atPath: dir.appendingPathComponent(entry.filename).path, contents: Data(count: 1024))

        let readiness = OfflineReadinessChecker.evaluate(model: entry, in: dir)
        guard case .incomplete = readiness.status else {
            return XCTFail("expected .incomplete for a 1 KB partial, got \(readiness.status)")
        }
    }
}
