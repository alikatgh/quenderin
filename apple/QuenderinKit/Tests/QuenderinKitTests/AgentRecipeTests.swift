import XCTest
@testable import QuenderinKit

/// Recipe matching is the fragile joint the design flagged — it must fire ONLY on clear intent with
/// all required tools present, never fuzzy-match an adjacent goal, and its re-anchor line must never
/// tell the model to "redo".
final class AgentRecipeTests: XCTestCase {
    private let allTools = ["mac.calendar.today", "mac.notes.create", "mac.clipboard.read",
                            "mac.mail.draft", "fs.list", "mac.finder.reveal", "mac.app.open", "calculator"]

    func testMatchesTheThreeIntendedGoals() {
        XCTAssertEqual(AgentRecipe.match(goal: "Make me a prep note for today", availableTools: allTools)?.title, "Morning brief")
        XCTAssertEqual(AgentRecipe.match(goal: "Draft an email from what I just copied", availableTools: allTools)?.title, "Copy to draft")
        XCTAssertEqual(AgentRecipe.match(goal: "Find my report and open it", availableTools: allTools)?.title, "Find and open")
    }

    func testDoesNotFalseTriggerOnAdjacentGoals() {
        // A bare calendar read is NOT the morning-brief recipe (no note intent).
        XCTAssertNil(AgentRecipe.match(goal: "what's on my calendar today", availableTools: allTools))
        // Plain "read my clipboard" is not the copy-to-draft recipe.
        XCTAssertNil(AgentRecipe.match(goal: "read my clipboard", availableTools: allTools))
        // A pure calculation must never match a recipe.
        XCTAssertNil(AgentRecipe.match(goal: "what is 15% of 200", availableTools: allTools))
    }

    func testRequiresEveryToolToBePresent() {
        // Morning brief needs BOTH calendar + notes; drop notes → no match.
        let missingNotes = allTools.filter { $0 != "mac.notes.create" }
        XCTAssertNil(AgentRecipe.match(goal: "Make me a prep note for today", availableTools: missingNotes))
    }

    func testNextStepLineTracksProgressAndNeverSaysRedo() {
        let r = AgentRecipe.all[0]   // Morning brief, 2 steps
        let atStart = r.nextStepLine(cursor: 0)
        XCTAssertTrue(atStart.contains("none yet"))
        XCTAssertTrue(atStart.contains("step 1"))
        XCTAssertTrue(atStart.contains("mac.calendar.today"))
        XCTAssertFalse(atStart.lowercased().contains("redo"), "must never tell the model to repeat a step")

        let midway = r.nextStepLine(cursor: 1)
        XCTAssertTrue(midway.contains("Done: step 1"))
        XCTAssertTrue(midway.contains("step 2"))

        let done = r.nextStepLine(cursor: 2)
        XCTAssertTrue(done.contains("all") && done.contains("done"))
        XCTAssertTrue(done.lowercased().contains("final answer"))
    }

    func testSkeletonNamesEachToolInOrder() {
        let s = AgentRecipe.all[2].skeleton()   // Find and open, 3 tools
        XCTAssertTrue(s.contains("fs.list"))
        XCTAssertTrue(s.contains("mac.finder.reveal"))
        XCTAssertTrue(s.contains("mac.app.open"))
        // Ordered 1, 2, 3.
        XCTAssertTrue(s.contains("1.") && s.contains("2.") && s.contains("3."))
    }
}
