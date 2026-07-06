import XCTest
@testable import QuenderinKit

/// Q-326 (twin of the UI's Q-273): chat markdown is untrusted LLM output. Links whose scheme isn't
/// http(s)/mailto must be neutralized so a `javascript:`/`data:` exfiltration link isn't one tap away.
final class MarkdownLinkSanitizeTests: XCTestCase {

    private func link(of markdown: String) -> URL? {
        let attr = (try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        let cleaned = sanitizeLinks(attr)
        for run in cleaned.runs where run.link != nil { return run.link }
        return nil
    }

    func testKeepsHttpAndMailto() {
        XCTAssertEqual(link(of: "[docs](https://quenderin.org)")?.scheme, "https")
        XCTAssertEqual(link(of: "[web](http://example.com)")?.scheme, "http")
        XCTAssertEqual(link(of: "[mail](mailto:a@b.com)")?.scheme, "mailto")
    }

    func testStripsDangerousSchemes() {
        // The link attribute is removed → renders as plain text, nothing tappable.
        XCTAssertNil(link(of: "[click](javascript:alert(1))"))
        XCTAssertNil(link(of: "[x](data:text/html,<script>)"))
        XCTAssertNil(link(of: "[f](file:///etc/passwd)"))
    }
}
