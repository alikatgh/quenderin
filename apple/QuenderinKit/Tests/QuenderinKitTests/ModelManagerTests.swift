import XCTest
@testable import QuenderinKit

final class ModelManagerTests: XCTestCase {
    private let small = ModelCatalog.smallest
    private var mid: ModelEntry { ModelCatalog.entry(id: "qwen3-4b")! }

    private func storage(_ entries: [(ModelEntry, Int64)]) -> InMemoryModelStorage {
        let s = InMemoryModelStorage()
        for (model, size) in entries { s.install(model.filename, sizeBytes: size) }
        return s
    }

    func testInstalledListsOnlyOnDiskModelsWithSizes() {
        let mgr = ModelManager(storage: storage([(small, 300), (mid, 4000)]))
        XCTAssertEqual(Set(mgr.installed().map(\.id)), [small.id, mid.id])
        XCTAssertEqual(mgr.totalBytesUsed, 4300)
    }

    func testActivePinnedToTopAndSetActiveRequiresInstalled() {
        let mgr = ModelManager(storage: storage([(small, 300), (mid, 4000)]))
        XCTAssertTrue(mgr.setActive(small.id))
        XCTAssertEqual(mgr.installed().first?.id, small.id, "active is pinned to the top regardless of size")
        XCTAssertFalse(mgr.setActive("not-installed-id"), "cannot activate a model that isn't on disk")
    }

    func testDeleteReclaimsBytesAndClearsActiveIfNeeded() {
        let mgr = ModelManager(storage: storage([(small, 300), (mid, 4000)]), activeModelID: mid.id)
        XCTAssertEqual(mgr.reclaimableBytes, 300, "everything except the active model is reclaimable")
        XCTAssertEqual(mgr.delete(mid.id), 4000)
        XCTAssertNil(mgr.activeModelID, "deleting the active model clears it")
        XCTAssertFalse(mgr.isInstalled(mid.id))
        XCTAssertEqual(mgr.totalBytesUsed, 300)
    }

    func testDeleteUninstalledIsNoOp() {
        let mgr = ModelManager(storage: storage([(small, 300)]))
        XCTAssertEqual(mgr.delete("qwen3-14b"), 0)
        XCTAssertEqual(mgr.totalBytesUsed, 300)
    }

    /// The real FileManager-backed storage that drives ModelManager in the app: it lists the model
    /// files actually on disk, reports their byte sizes, and deletes them. Exercised against a temp dir.
    func testFileManagerModelStorageReadsSizesAndDeletes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two real model files (catalog filenames) of known sizes; a hidden file is ignored.
        try Data(count: 300).write(to: dir.appendingPathComponent(small.filename))
        try Data(count: 4000).write(to: dir.appendingPathComponent(mid.filename))
        try Data(count: 9).write(to: dir.appendingPathComponent(".DS_Store"))

        let mgr = ModelManager(storage: FileManagerModelStorage(directory: dir), activeModelID: mid.id)
        XCTAssertEqual(Set(mgr.installed().map(\.id)), [small.id, mid.id])
        XCTAssertEqual(mgr.totalBytesUsed, 4300, "sizes read from real files; hidden file excluded")
        XCTAssertEqual(mgr.reclaimableBytes, 300)

        XCTAssertEqual(mgr.delete(small.id), 300)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(small.filename).path),
                       "delete removes the file from disk")
        XCTAssertEqual(mgr.totalBytesUsed, 4000)
    }
}
