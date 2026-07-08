import XCTest
@testable import QuenderinKit

/// The runtime registry that remembers searched (non-catalog) models across launches, and the
/// collision-safe local filenames that keep two same-named HF downloads from clobbering each other.
final class SideloadedModelsTests: XCTestCase {

    private func freshStore() -> (SideloadedModels, UserDefaults) {
        let suite = "test.sideloaded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SideloadedModels(defaults: defaults), defaults)
    }

    private func entry(id: String, filename: String) -> ModelEntry {
        ModelEntry(id: id, label: "L", filename: filename, ramGB: 5, sizeLabel: "4.0 GB download",
                   paramsBillions: 4, quantization: "Q4_K_M", urlString: "https://x/\(filename)", sha256: "sha")
    }

    func testRecordAndResolveRoundTrips() {
        let (store, _) = freshStore()
        let e = entry(id: "hf:acme/Model-GGUF/m.gguf", filename: "acme_Model-GGUF__m.gguf")
        store.record(e)
        XCTAssertEqual(store.entry(id: e.id)?.filename, e.filename)
        XCTAssertEqual(store.all.count, 1)
    }

    func testRecordDeDupesById() {
        let (store, _) = freshStore()
        store.record(entry(id: "hf:same", filename: "a.gguf"))
        store.record(entry(id: "hf:same", filename: "a.gguf"))   // same id twice → one row, newest wins
        XCTAssertEqual(store.all.count, 1)
    }

    func testRemoveForgets() {
        let (store, _) = freshStore()
        let e = entry(id: "hf:gone", filename: "g.gguf")
        store.record(e)
        store.remove(id: e.id)
        XCTAssertNil(store.entry(id: e.id))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testPersistsAcrossInstances() {
        let suite = "test.sideloaded.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        SideloadedModels(defaults: defaults).record(entry(id: "hf:kept", filename: "k.gguf"))
        // A brand-new instance over the SAME defaults (simulating a relaunch) still sees it.
        XCTAssertEqual(SideloadedModels(defaults: defaults).entry(id: "hf:kept")?.filename, "k.gguf")
    }

    // MARK: collision-safe local filenames

    func testSafeLocalFilenameNamespacesByRepoAndKeepsGguf() {
        let name = HuggingFaceCatalog.safeLocalFilename(repo: "bartowski/Qwen3-4B-GGUF", filename: "Qwen3-4B-Q4_K_M.gguf")
        XCTAssertTrue(name.hasSuffix(".gguf"), "the GGUF extension must survive so magic/Finder still recognise it")
        XCTAssertTrue(name.contains("Qwen3-4B-Q4_K_M.gguf"), "the original filename is preserved after the repo slug")
        XCTAssertFalse(name.contains("/"), "no path separators may leak into a filename")
    }

    func testSameFilenameFromDifferentReposDoesNotCollide() {
        let a = HuggingFaceCatalog.safeLocalFilename(repo: "owner-a/Model-GGUF", filename: "model-Q4_K_M.gguf")
        let b = HuggingFaceCatalog.safeLocalFilename(repo: "owner-b/Model-GGUF", filename: "model-Q4_K_M.gguf")
        XCTAssertNotEqual(a, b, "two repos shipping the same filename must map to distinct local files")
    }

    func testCandidateFilenameIsNamespacedAndCollisionSafe() {
        let q1 = HFQuant(repo: "teamA/Llama-GGUF", filename: "Llama-Q4_K_M.gguf", sizeBytes: 4_000_000_000, sha256: "1")
        let q2 = HFQuant(repo: "teamB/Llama-GGUF", filename: "Llama-Q4_K_M.gguf", sizeBytes: 4_000_000_000, sha256: "2")
        let c1 = HuggingFaceCatalog.candidate(from: q1, label: "A")
        let c2 = HuggingFaceCatalog.candidate(from: q2, label: "B")
        XCTAssertNotEqual(c1.filename, c2.filename, "candidate local filenames must not collide across repos")
        // The REMOTE download URL still points at the real HF path (only the local name is namespaced).
        XCTAssertEqual(c1.downloadURL?.absoluteString,
                       "https://huggingface.co/teamA/Llama-GGUF/resolve/main/Llama-Q4_K_M.gguf?download=true")
    }
}
