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
}
