import XCTest
@testable import QuenderinKit

#if canImport(SwiftUI)
final class MarkdownCodeCopyTests: XCTestCase {
    func testFencedCodeCopyPreservesOriginalContentBytes() {
        let fixtures: [(String, [String])] = [
            ("Before\r\n```swift\r\nlet value = 1\r\n```\r\nAfter", ["let value = 1\r\n"]),
            ("```\n\n  indented\n\n\n```", ["\n  indented\n\n\n"]),
            ("```\r\n\r\n内容 = \"Сайн уу 👩🏽‍💻\"\r\n\r\n```", ["\r\n内容 = \"Сайн уу 👩🏽‍💻\"\r\n\r\n"]),
            ("```text\r\n\r\nunfinished\r\n", ["\r\nunfinished\r\n"]),
            ("```\nfirst\n```\nBetween\n```\nsecond", ["first\n", "second"]),
            ("```", [""])
        ]
        for (source, expected) in fixtures {
            XCTAssertEqual(markdownFencedCodeCopies(in: source).map { Array($0.utf8) }, expected.map { Array($0.utf8) })
        }
    }
}
#endif
