import XCTest
@testable import QuenderinKit

/// The code-block tokenizer behind MarkdownText's syntax highlighting. The load-bearing invariant:
/// segments must reassemble to EXACTLY the original code — highlighting may never eat, reorder,
/// or invent characters.
final class CodeHighlightTests: XCTestCase {

    private func reassembled(_ code: String, lang: String?) -> String {
        tokenizeCode(code, language: lang).map(\.text).joined()
    }

    func testSegmentsReassembleToOriginal() {
        let samples: [(String, String?)] = [
            ("# Lists\nmy_list = [1, 2, 3, 4]\nprint(\"First:\", my_list[0])", "python"),
            ("const x = 'it\\'s';\n// done\nlet n = 0x1F;", "javascript"),
            ("\n\nleading empty lines\n", nil),
            ("unterminated = \"oops", "python"),
            ("", nil),
            ("emoji 🎉 in code\nlet s = \"héllo\"", "swift"),
        ]
        for (code, lang) in samples {
            XCTAssertEqual(reassembled(code, lang: lang), code, "lossy tokenization for lang \(lang ?? "nil")")
        }
    }

    func testPythonCommentStringNumberKeyword() {
        let segs = tokenizeCode("def f():  # add\n    return 42 + \"x\"", language: "python")
        XCTAssertTrue(segs.contains { $0.kind == .keyword && $0.text == "def" })
        XCTAssertTrue(segs.contains { $0.kind == .comment && $0.text == "# add" })
        XCTAssertTrue(segs.contains { $0.kind == .keyword && $0.text == "return" })
        XCTAssertTrue(segs.contains { $0.kind == .number && $0.text == "42" })
        XCTAssertTrue(segs.contains { $0.kind == .string && $0.text == "\"x\"" })
    }

    func testCommentMarkersRespectLanguage() {
        // "//" is not a comment in Python; "#" is not one in JS.
        XCTAssertFalse(tokenizeCode("a // b", language: "python").contains { $0.kind == .comment })
        XCTAssertFalse(tokenizeCode("a # b", language: "javascript").contains { $0.kind == .comment })
        // An UNKNOWN language accepts both (LLM snippets default Python-ish).
        XCTAssertTrue(tokenizeCode("# b", language: nil).contains { $0.kind == .comment })
        XCTAssertTrue(tokenizeCode("// b", language: nil).contains { $0.kind == .comment })
    }

    func testIdentifierContainingKeywordStaysPlain() {
        // "iffy" must not light up because it starts with "if"; "my_list[0]" has no number-in-name split.
        let segs = tokenizeCode("iffy = my_list2", language: "python")
        XCTAssertFalse(segs.contains { $0.kind == .keyword })
        XCTAssertFalse(segs.contains { $0.kind == .number })
    }
}
