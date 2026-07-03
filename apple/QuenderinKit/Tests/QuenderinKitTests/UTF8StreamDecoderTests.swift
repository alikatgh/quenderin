import XCTest
@testable import QuenderinKit

/// The split-character bug class: BPE tokens end mid-character (every Cyrillic letter is
/// 2 bytes, emoji 4) and naive per-token decoding emits "�". The decoder must reassemble
/// EVERY split without ever inventing or dropping a byte.
final class UTF8StreamDecoderTests: XCTestCase {

    /// Feed `text`'s UTF-8 bytes in every possible two-chunk split — the reassembled
    /// stream must equal the original exactly, with zero replacement characters.
    private func assertAllSplitsSurvive(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let bytes = Array(text.utf8)
        for cut in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            var out = decoder.feed(Array(bytes[0..<cut]))
            out += decoder.feed(Array(bytes[cut...]))
            out += decoder.flush()
            XCTAssertEqual(out, text, "split at byte \(cut)", file: file, line: line)
            XCTAssertFalse(out.contains("\u{FFFD}"), "replacement char at split \(cut)", file: file, line: line)
        }
    }

    func testCyrillicSurvivesEverySplit() {
        assertAllSplitsSurvive("Привет, мир")   // the user's own chats are Russian
    }

    func testEmojiAndCJKSurviveEverySplit() {
        assertAllSplitsSurvive("Hi 🌲🧝‍♀️ 你好")
    }

    func testAsciiPassesStraightThrough() {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.feed(Array("hello".utf8)), "hello")
        XCTAssertEqual(decoder.flush(), "")
    }

    func testTokenByTokenSingleBytes() {
        // Worst case: the stream arrives ONE BYTE at a time.
        let text = "ёлка 🎄"
        var decoder = UTF8StreamDecoder()
        var out = ""
        for byte in Array(text.utf8) { out += decoder.feed([byte]) }
        out += decoder.flush()
        XCTAssertEqual(out, text)
    }

    func testTruncatedStreamFlushesLossilyNotFatally() {
        var decoder = UTF8StreamDecoder()
        _ = decoder.feed([0xF0, 0x9F])          // half an emoji, then the stream dies
        XCTAssertEqual(decoder.flush(), "\u{FFFD}")   // honest replacement, no crash, no hang
    }

    func testInvalidLeadByteDoesNotStickForever() {
        var decoder = UTF8StreamDecoder()
        let out = decoder.feed([0xFF, 0x41])    // invalid byte then 'A'
        XCTAssertTrue(out.hasSuffix("A"))       // the garbage byte decays to �, 'A' flows through
    }
}
