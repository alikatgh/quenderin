import XCTest
@testable import QuenderinKit

final class DownloadStoreTests: XCTestCase {

    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qkit-store-\(UUID().uuidString).json")
    }

    func testUpsertAndQuery() async {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DownloadStore(fileURL: url)
        await store.upsert(PersistedDownload(modelId: "m1", fileName: "m1.gguf", urlString: "https://x/m1", destinationPath: "/tmp/m1.gguf", totalBytes: 100))
        let record = await store.record(modelId: "m1")
        XCTAssertEqual(record?.fileName, "m1.gguf")
        let count = await store.all().count
        XCTAssertEqual(count, 1)
    }

    func testPersistsAcrossInstances() async {
        // The whole point: a fresh DownloadStore (i.e. app relaunch) recovers state.
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DownloadStore(fileURL: url)
        await store.upsert(PersistedDownload(modelId: "m1", fileName: "m1.gguf", urlString: "https://x", destinationPath: "/tmp/m1.gguf", bytesDownloaded: 42, totalBytes: 100))

        let reborn = DownloadStore(fileURL: url)
        let record = await reborn.record(modelId: "m1")
        XCTAssertEqual(record?.bytesDownloaded, 42)
        XCTAssertEqual(record?.fractionComplete, 0.42)
    }

    func testResumableFiltersByState() async {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DownloadStore(fileURL: url)
        await store.upsert(PersistedDownload(modelId: "run", fileName: "a", urlString: "u", destinationPath: "p", state: .running))
        await store.upsert(PersistedDownload(modelId: "done", fileName: "b", urlString: "u", destinationPath: "p", state: .completed))
        let resumable = await store.resumable()
        XCTAssertEqual(resumable.map(\.modelId), ["run"])
    }

    func testUpdateProgressAndRemove() async {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DownloadStore(fileURL: url)
        await store.upsert(PersistedDownload(modelId: "m", fileName: "f", urlString: "u", destinationPath: "p", totalBytes: 200))
        await store.updateProgress(modelId: "m", bytesDownloaded: 100, totalBytes: 200)
        let mid = await store.record(modelId: "m")
        XCTAssertEqual(mid?.fractionComplete, 0.5)
        await store.remove(modelId: "m")
        let gone = await store.record(modelId: "m")
        XCTAssertNil(gone)
    }
}
