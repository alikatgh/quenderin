import XCTest
@testable import QuenderinKit

/// The anti-credibility-killer: verbatim paragraph loops get detected and collapsed.
/// Mirrors the CoreVerify "degeneration guard" checks (Kotlin twin) case for case.
final class DegenerationGuardTests: XCTestCase {

    private let para = "Quender was a forest elf, a member of the slender and agile forest elves."

    func testCollapsesRunsOfIdenticalSubstantialParagraphs() {
        let wall = "Once upon a time.\n\n" + Array(repeating: para, count: 4).joined(separator: "\n\n")
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs(wall),
                       "Once upon a time.\n\n" + para)
    }

    func testKeepsDistinctParagraphsAndShortIntentionalRepeats() {
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs("A tale.\n\nYes.\n\nYes.\n\nThe end."),
                       "A tale.\n\nYes.\n\nYes.\n\nThe end.")   // short repeats are allowed to be style
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs("First idea here.\n\nSecond idea here."),
                       "First idea here.\n\nSecond idea here.")
    }

    func testDetectsVerbatimLoopingTailButNotNormalProse() {
        let loop = Array(repeating: para, count: 8).joined(separator: " ")
        XCTAssertTrue(DegenerationGuard.looksDegenerate(loop))
        XCTAssertFalse(DegenerationGuard.looksDegenerate(
            "The forest was a vast and varied tapestry of life, where a variety of animals and plants "
          + "could be found, and every day brought a different weather, a different visitor, and a "
          + "different small problem to solve."))
    }

    func testShortTextIsNeverFlagged() {
        XCTAssertFalse(DegenerationGuard.looksDegenerate("hello hello hello"))
    }

    // Twin-seam normalization (degeneration P2/P3): CODE POINTS + ONE trim set. The same pins
    // live in CoreVerify — the same emoji/NEL text must answer the same on both platforms
    // (Kotlin's UTF-16 units counted every astral char twice; Swift graphemes undercounted ZWJ).
    func testEmojiWindowCountsCodePointsOnBothPlatforms() {
        let emoji240 = String(repeating: "🌀", count: 240)   // below the 160×3 window on both now
        let emoji480 = String(repeating: "🌀", count: 480)   // a genuine 3× loop of the window
        XCTAssertFalse(DegenerationGuard.looksDegenerate(emoji240))
        XCTAssertTrue(DegenerationGuard.looksDegenerate(emoji480))
    }

    func testCollapseGateCountsCodePointsAndSharesTheTrimSet() {
        let emojiPara = String(repeating: "🌀", count: 30)   // 30 cps — below the 40-cp gate on both
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs("\(emojiPara)\n\n\(emojiPara)"),
                       "\(emojiPara)\n\n\(emojiPara)")
        // The unioned trim set: NEL (this side always trimmed) AND U+001C (newly trimmed here,
        // Java-side always) both make a trailing-junk duplicate collapse identically.
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs("\(para)\n\n\(para)\u{0085}"), para)
        XCTAssertEqual(DegenerationGuard.collapseRepeatedParagraphs("\(para)\n\n\(para)\u{001C}"), para)
    }
}
