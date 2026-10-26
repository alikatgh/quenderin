import Foundation
import XCTest
@testable import QuenderinKit

#if canImport(Combine)
@MainActor final class RemoteHarnessPresentationTests: XCTestCase {
    func testRemoteFormattingBudgetRejectsLargeDenseAndExcessiveBlockWork() {
        XCTAssertTrue(RemoteHarnessTextBudget.allowsFormatting("**你好** and `Сайн уу`"))
        XCTAssertTrue(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "[", count: 128)))
        XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "[", count: 129)))
        XCTAssertTrue(RemoteHarnessTextBudget.allowsFormatting(Array(repeating: "# heading", count: 128).joined(separator: "\n")))
        XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(Array(repeating: "# heading", count: 129).joined(separator: "\n")))
        XCTAssertTrue(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "a", count: 16_384)))
        XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "a", count: 16_385)))
        XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "x", count: 2 * 1024 * 1024)))
        XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(String(repeating: "[*_`", count: 2 * 1024 * 1024 / 4)))
    }
    func testRawFallbackPagesPreserveTwoMiBUnicodeCRLFAndCodeExactly() {
        let fixtures = [
            String(repeating: "x", count: 2 * 1024 * 1024),
            String(repeating: "中👩🏽‍💻e\u{301}\r\n", count: 1024),
            "```swift\r\n\r\n" + String(repeating: "\tlet 名 = \"🦊\"  \r\n", count: 1500) + "\r\n```"
        ]
        for source in fixtures {
            XCTAssertFalse(RemoteHarnessTextBudget.allowsFormatting(source))
            let count = RemoteHarnessRawTextPage(source, index: 0).count
            let pages = (0..<count).map { RemoteHarnessRawTextPage(source, index: $0).text }
            XCTAssertTrue(pages.allSatisfy { $0.utf8.count <= RemoteHarnessTextBudget.maximumRawPageBytes && !$0.isEmpty })
            XCTAssertEqual(Array(pages.joined().utf8), Array(source.utf8))
            XCTAssertEqual(RemoteHarnessRawTextPage(source, index: Int.max).index, count - 1)
            XCTAssertEqual(RemoteHarnessRawTextPage(source, index: -1).index, 0)
        }
        XCTAssertEqual(RemoteHarnessRawTextPage("", index: 0).count, 1)
        XCTAssertEqual(RemoteHarnessRawTextPage("", index: 0).text, "")
    }
    func testExplicitConnectionIntentPersistsIndependentlyOfPresentationAndJournal() throws {
        let name = "RemoteHarnessRecoveryIntentTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = RemoteHarnessClientRecoveryPreferences(defaults: defaults)
        XCTAssertTrue(try original.loadAutomaticRecoveryIntent())
        try original.saveAutomaticRecoveryIntent(false)
        let recreated = RemoteHarnessClientRecoveryPreferences(defaults: defaults)
        XCTAssertFalse(try recreated.loadAutomaticRecoveryIntent())
        try recreated.saveAutomaticRecoveryIntent(true)
        XCTAssertTrue(try original.loadAutomaticRecoveryIntent())
    }
    func testPresentationRestoresOnlyBoundedDeviceLocalValues() throws {
        let name = "RemoteHarnessPresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RemoteHarnessPresentationPreferences(defaults: defaults)
        XCTAssertTrue(preferences.wrapsCode); XCTAssertEqual(preferences.textSize, .standard)
        preferences.wrapsCode = false; preferences.textSize = .largest
        let restored = RemoteHarnessPresentationPreferences(defaults: defaults)
        XCTAssertFalse(restored.wrapsCode); XCTAssertEqual(restored.textSize, .largest)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? []),
                       Set([RemoteHarnessPresentationPreferences.wrapsCodeKey, RemoteHarnessPresentationPreferences.textSizeKey]))
        defaults.set("unsupported-size", forKey: RemoteHarnessPresentationPreferences.textSizeKey)
        defaults.set("unsupported-wrap", forKey: RemoteHarnessPresentationPreferences.wrapsCodeKey)
        let unknown = RemoteHarnessPresentationPreferences(defaults: defaults)
        XCTAssertTrue(unknown.wrapsCode); XCTAssertEqual(unknown.textSize, .standard)
    }
}
#endif
