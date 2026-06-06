import XCTest
@testable import QuenderinKit

final class SafetyBlocklistTests: XCTestCase {

    func testBlocksFinancialActions() {
        XCTAssertTrue(SafetyBlocklist.isBlocked("Tap Pay to complete"))
        XCTAssertTrue(SafetyBlocklist.isBlocked("Confirm transfer of $500"))
        XCTAssertTrue(SafetyBlocklist.isBlocked("Enter your credit card number"))
    }

    func testBlocksDestructiveAndCredentialActions() {
        XCTAssertTrue(SafetyBlocklist.isBlocked("Delete all photos"))
        XCTAssertTrue(SafetyBlocklist.isBlocked("Factory reset this device"))
        XCTAssertTrue(SafetyBlocklist.isBlocked("Type the password"))
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(SafetyBlocklist.isBlocked("PAYMENT REQUIRED"))
    }

    func testAllowsSafeText() {
        XCTAssertFalse(SafetyBlocklist.isBlocked("Open the weather app"))
        XCTAssertFalse(SafetyBlocklist.isBlocked("Summarize this article"))
    }

    func testMatchesExplainWhy() {
        let matches = SafetyBlocklist.matches(in: "Delete the file then pay the invoice")
        XCTAssertTrue(matches.contains("delete"))
        XCTAssertTrue(matches.contains("pay"))
    }
}
