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

    // MARK: dynamic planning — parsePlan validation + the dynamic re-anchor's abandonable wording

    private struct PlanTool: AgentTool {
        let name: String
        let purpose: String
        func run(_ input: String) async throws -> String { "" }
    }
    private let planTools: [AgentTool] = [
        PlanTool(name: "fs.list", purpose: "List files in the workspace folder."),
        PlanTool(name: "fs.move", purpose: "Move a file into a subfolder. Use to tidy."),
        PlanTool(name: "mac.app.open", purpose: "Open an app by name."),
    ]

    func testParsePlanDropsUnregisteredToolNames() {
        // A hallucinated tool ("bogus.tool") is filtered out; the two real steps survive.
        let calls = [ToolCall(name: "fs.list", input: ""), ToolCall(name: "bogus.tool", input: ""),
                     ToolCall(name: "fs.move", input: "")]
        let recipe = AgentRecipe.parsePlan(calls, tools: planTools, maxSteps: 6)
        XCTAssertEqual(recipe?.steps.map(\.toolHint), ["fs.list", "fs.move"])
        XCTAssertEqual(recipe?.isDynamic, true)
    }

    func testParsePlanRejectsFewerThanTwoRealSteps() {
        // One real tool + one hallucinated → only 1 survivor → nil (nothing multi-step; reactive loop).
        let calls = [ToolCall(name: "fs.list", input: ""), ToolCall(name: "nope", input: "")]
        XCTAssertNil(AgentRecipe.parsePlan(calls, tools: planTools, maxSteps: 6))
        // Zero real tools → nil.
        XCTAssertNil(AgentRecipe.parsePlan([ToolCall(name: "x", input: "")], tools: planTools, maxSteps: 6))
    }

    func testParsePlanCollapsesConsecutiveDuplicateTools() {
        // fs.list twice in a row is ONE step (1 step == 1 tool, the cursor's 1:1 invariant).
        let calls = [ToolCall(name: "fs.list", input: "a"), ToolCall(name: "fs.list", input: "b"),
                     ToolCall(name: "fs.move", input: "")]
        let recipe = AgentRecipe.parsePlan(calls, tools: planTools, maxSteps: 6)
        XCTAssertEqual(recipe?.steps.map(\.toolHint), ["fs.list", "fs.move"])
    }

    func testParsePlanClampsARunawayPlanToMaxSteps() {
        // A 20-tool hallucination clamps to <= maxSteps.
        let calls = (0..<20).map { _ in ToolCall(name: "fs.list", input: "") }
            + (0..<20).map { _ in ToolCall(name: "fs.move", input: "") }
        let recipe = AgentRecipe.parsePlan(calls, tools: planTools, maxSteps: 3)
        XCTAssertNotNil(recipe)
        XCTAssertLessThanOrEqual(recipe!.steps.count, 3)
    }

    func testParsePlanTitlesAreDerivedFromToolPurposeNotModelText() {
        // A ToolCall carries only a tool NAME + input — no label field — so the title can only come
        // from the tool's own `purpose`. Prove it: the input string never leaks into the title.
        let calls = [ToolCall(name: "fs.list", input: "MODEL-SUPPLIED LABEL"),
                     ToolCall(name: "fs.move", input: "ANOTHER LABEL")]
        let recipe = AgentRecipe.parsePlan(calls, tools: planTools, maxSteps: 6)
        XCTAssertEqual(recipe?.steps[0].title, "List files in the workspace folder")
        XCTAssertFalse(recipe?.steps.contains { $0.title.contains("LABEL") } ?? true,
                       "no model-supplied text may enter a checklist title")
    }

    func testDynamicNextStepLineIsAbandonableAndNeverAssertsCompletion() {
        let recipe = AgentRecipe.parsePlan(
            [ToolCall(name: "fs.list", input: ""), ToolCall(name: "fs.move", input: "")],
            tools: planTools, maxSteps: 6)!
        // Mid-plan: the tool is a soft suggestion the model may override — never a firm order.
        let mid = recipe.nextStepLine(cursor: 0)
        XCTAssertTrue(mid.contains("try fs.list"))
        XCTAssertTrue(mid.lowercased().contains("if a different tool"),
                      "a dynamic hint must invite the model to pick a better tool")
        XCTAssertFalse(mid.contains("suggested tool"), "the firm curated wording must not leak into a dynamic plan")
        // All steps green: a model-guessed denominator must NOT push 'give the final answer now'.
        let done = recipe.nextStepLine(cursor: recipe.steps.count)
        XCTAssertTrue(done.lowercased().contains("confirm the goal is actually met"))
        XCTAssertFalse(done.lowercased().contains("final answer now"),
                       "a dynamic plan greening early must not assert completion")
    }
}
