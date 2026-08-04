import XCTest
@testable import QuenderinKit

final class DocumentTextExtractorTests: XCTestCase {
    func testImageAttachmentsAreRejectedWithVisionHonesty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("q-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("photo.jpg")
        // Minimal non-UTF8 bytes so the text path would fail anyway — name gate should fire first.
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)

        let result = DocumentTextExtractor.extract(name: "photo.jpg", url: url)
        guard case .rejected(let reason) = result else {
            return XCTFail("expected image rejection, got \(result)")
        }
        XCTAssertTrue(reason.lowercased().contains("vision"), reason)
        XCTAssertTrue(reason.lowercased().contains("image") || reason.lowercased().contains("photo"), reason)
    }

    func testPlainTextStillExtracts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("q-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("note.txt")
        try "hello world".data(using: .utf8)!.write(to: url)
        let result = DocumentTextExtractor.extract(name: "note.txt", url: url)
        guard case .document(let doc) = result else {
            return XCTFail("expected document, got \(result)")
        }
        XCTAssertEqual(doc.text, "hello world")
    }
}
