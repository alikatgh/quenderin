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
}
