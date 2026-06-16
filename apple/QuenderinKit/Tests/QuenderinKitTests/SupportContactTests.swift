import XCTest
@testable import QuenderinKit

final class SupportContactTests: XCTestCase {
    func testReportMailtoTargetsTheSupportAddress() throws {
        let url = try XCTUnwrap(SupportContact.reportMailto(reportedText: "hello", context: "chat"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("mailto:\(SupportContact.reportEmail)?"), "must address the support email: \(s)")
        XCTAssertTrue(s.contains("subject="))
        XCTAssertTrue(s.contains("body="))
    }

    func testReportMailtoPercentEncodesSpecialCharsSoOutputCannotBreakTheURL() throws {
        // Model output with query sub-delimiters must be encoded, not left literal.
        let url = try XCTUnwrap(SupportContact.reportMailto(reportedText: "danger & death = bad?", context: "agent"))
        let s = url.absoluteString
        XCTAssertFalse(s.contains("danger & death"), "raw '&'/spaces must be encoded")
        XCTAssertTrue(s.contains("danger") && s.contains("death"), "the snippet is still present, encoded")
        XCTAssertNotNil(URL(string: s), "stays a valid URL")
    }

    func testDisclaimerIsNonEmpty() {
        XCTAssertFalse(SupportContact.aiDisclaimer.isEmpty)
    }
}
