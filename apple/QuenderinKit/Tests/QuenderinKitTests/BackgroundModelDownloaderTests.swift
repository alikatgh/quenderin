import XCTest
@testable import QuenderinKit

/// Regression guard for review finding C3-2: the background downloader must resolve the CATALOG
/// ID from the download URL (not the filename), or the SHA-256 integrity gate silently downgrades
/// to magic-only because `ModelCatalog.entry(id:)` can't find a filename.
final class BackgroundModelDownloaderTests: XCTestCase {
    func testResolvesCatalogIdFromURLSoTheIntegrityGateHasTheHash() throws {
        let model = try XCTUnwrap(ModelCatalog.entry(id: "qwen3-14b"))
        let url = try XCTUnwrap(model.downloadURL)
        let dest = URL(fileURLWithPath: "/tmp/models/\(model.filename)")

        let resolved = BackgroundModelDownloader.catalogModelId(for: url, destination: dest)
        XCTAssertEqual(resolved, "qwen3-14b", "must resolve to the catalog id, not the filename")
        // …and that id must resolve to an entry carrying a pinned sha256 — exactly what the gate needs.
        XCTAssertNotNil(ModelCatalog.entry(id: resolved)?.sha256)
    }

    func testFallsBackToFilenameForOffCatalogURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/custom/my-model.gguf"))
        let dest = URL(fileURLWithPath: "/tmp/models/my-model.gguf")
        XCTAssertEqual(
            BackgroundModelDownloader.catalogModelId(for: url, destination: dest),
            "my-model.gguf"
        )
    }
}
