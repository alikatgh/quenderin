import XCTest
#if canImport(PDFKit)
import PDFKit
#endif
@testable import QuenderinKit

/// fs.rename + fs.trash on the write spine, and PDF extraction. Twin of the Kotlin CoreVerify
/// rename/trash checks (PDF is Apple-only — PDFKit; the Android gap is recorded in the plan).
final class RenameTrashPDFTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRenameRenamesUndoesAndNeverOverwrites() async throws {
        try "A".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: root.appendingPathComponent("final.txt"), atomically: true, encoding: .utf8)
        let journal = UndoJournal()
        let rename = FileRenameCapability(workspace: { [root] in root }, journal: journal)

        let collision = try await rename.run("draft.txt to final.txt")
        XCTAssertTrue(collision.contains("refusing to overwrite"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("final.txt"), encoding: .utf8), "B")

        let ok = try await rename.run("draft.txt to report.txt")
        XCTAssertTrue(ok.contains("Renamed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.txt").path))
        XCTAssertEqual(journal.undoLast().contains("back to where it was"), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.txt").path),
                      "undo restores the ORIGINAL name")

        let hostile = try await rename.run("../evil to x")
        XCTAssertTrue(hostile.contains("plain names") || hostile.contains("Input must be"))
    }

    func testTrashMovesToVisibleTrashAndUndoRestores() async throws {
        try "junk".write(to: root.appendingPathComponent("old.log"), atomically: true, encoding: .utf8)
        let journal = UndoJournal()
        let trash = FileTrashCapability(workspace: { [root] in root }, journal: journal)

        let out = try await trash.run("old.log")
        XCTAssertTrue(out.contains("Moved \"old.log\" to Trash/"))
        XCTAssertTrue(out.contains("nothing is deleted"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash/old.log").path))

        _ = journal.undoLast()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.log").path))

        let preview = try await trash.plan("old.log")
        XCTAssertTrue(preview.mutates)
        XCTAssertTrue(preview.summary.contains("undoable — not deleted"))
    }

    #if canImport(PDFKit)
    func testPDFExtractionReadsTextAndRefusesTextlessScans() throws {
        // Build a real one-page PDF with Core Graphics text so the test needs no fixture file.
        let pdfURL = root.appendingPathComponent("doc.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: "the elf reads PDFs locally",
                                            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        guard case .document(let doc) = DocumentTextExtractor.extract(name: "doc.pdf", url: pdfURL) else {
            return XCTFail("a text PDF should extract")
        }
        XCTAssertTrue(doc.text.contains("the elf reads PDFs locally"))

        // A PDF with an empty page has no extractable text → honest refusal, not empty context.
        let blankURL = root.appendingPathComponent("scan.pdf")
        let blankCtx = CGContext(blankURL as CFURL, mediaBox: &mediaBox, nil)!
        blankCtx.beginPDFPage(nil); blankCtx.endPDFPage(); blankCtx.closePDF()
        guard case .rejected(let reason) = DocumentTextExtractor.extract(name: "scan.pdf", url: blankURL) else {
            return XCTFail("a textless PDF must be refused")
        }
        XCTAssertTrue(reason.contains("no extractable text"))
    }
    #endif
}
