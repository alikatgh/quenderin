#if canImport(SwiftUI)
import XCTest
@testable import QuenderinKit

/// Pins Q-010: a drag-imported GGUF matching a catalog entry is checked against that entry's pinned
/// SHA-256, not magic-only. A file with the right NAME and GGUF magic but the wrong bytes must be
/// rejected — previously it passed (expectedSHA256 was hard-coded nil).
@MainActor
final class ImportGGUFIntegrityTests: XCTestCase {

    func testImportRejectsCatalogFileWithWrongChecksum() async throws {
        // Pick a catalog entry that pins a SHA-256.
        guard let entry = ModelCatalog.models.first(where: { ($0.sha256?.isEmpty == false) }) else {
            throw XCTSkip("no catalog entry pins a sha256")
        }
        // A file named like the catalog model, with valid GGUF magic but arbitrary (wrong) bytes.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qkit-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent(entry.filename)
        var bytes = Data([0x47, 0x47, 0x55, 0x46])   // "GGUF" magic
        bytes.append(contentsOf: Array("not the real model bytes".utf8))
        try bytes.write(to: src)

        let result = await ModelLibraryController.shared.importGGUF(at: src)

        XCTAssertEqual(result, .invalid(entry.filename),
                       "a catalog-named GGUF with the wrong checksum must be rejected (Q-010), not imported")
    }
}
#endif
