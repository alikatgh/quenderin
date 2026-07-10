import XCTest
@testable import QuenderinKit

final class AgentRunExporterTests: XCTestCase {
    func testAnsweredRunRendersWalkthrough() {
        let run = AgentRun(
            steps: [
                AgentStep(decision: .useTool(name: "calculator", input: "2+2"), observation: "4"),
                AgentStep(decision: .finalAnswer("The answer is 4."), observation: nil),
            ],
            answer: "The answer is 4.",
            haltReason: .answered
        )
        let md = AgentRunExporter.markdown(run, goal: "What is 2+2?")
        XCTAssertTrue(md.contains("# Agent walkthrough: What is 2+2?"))
        XCTAssertTrue(md.contains("2 steps"))                              // plural
        // Glanceable verification summary — people-facing tool labels (not raw ids).
        XCTAssertTrue(md.contains("**Outcome: answered.** Tools used: Calculator."))
        XCTAssertTrue(md.contains("**1. Calculator** — 2+2 → 4"))
        XCTAssertTrue(md.contains("**2. Final answer**"))
        XCTAssertTrue(md.contains("**Answer:** The answer is 4."))
        XCTAssertFalse(md.contains("Halted:"))                            // answered → no halt line
    }

    func testHaltedRunShowsReasonNotAnswer() {
        let run = AgentRun(
            steps: [AgentStep(decision: .useTool(name: "echo", input: "hi"), observation: "hi")],
            answer: nil,
            haltReason: .maxSteps
        )
        let md = AgentRunExporter.markdown(run, goal: "")
        XCTAssertTrue(md.contains("# Agent walkthrough: Agent run"))      // empty goal → default heading
        XCTAssertTrue(md.contains("1 step."))                            // singular
        XCTAssertTrue(md.contains("**Outcome: stopped at the step limit.** Tools used: Echo."))
        XCTAssertTrue(md.contains("**Halted:** The agent reached its step limit"))
        XCTAssertFalse(md.contains("**Answer:**"))
    }

    func testDirectAnswerRunReportsNoToolsUsed() {
        let run = AgentRun(
            steps: [AgentStep(decision: .finalAnswer("Paris."), observation: nil)],
            answer: "Paris.",
            haltReason: .answered
        )
        let md = AgentRunExporter.markdown(run, goal: "Capital of France?")
        XCTAssertTrue(md.contains("**Outcome: answered.** No tools used."))   // no useTool steps
    }

    func testDeduplicatesRepeatedToolInSummary() {
        let run = AgentRun(
            steps: [
                AgentStep(decision: .useTool(name: "calculator", input: "2+2"), observation: "4"),
                AgentStep(decision: .useTool(name: "calculator", input: "4*4"), observation: "16"),
                AgentStep(decision: .finalAnswer("Done."), observation: nil),
            ],
            answer: "Done.",
            haltReason: .answered
        )
        let md = AgentRunExporter.markdown(run, goal: "math")
        XCTAssertTrue(md.contains("**Outcome: answered.** Tools used: Calculator."))   // listed once
    }

    func testHumanizesMacCapabilityInWalkthrough() {
        let run = AgentRun(
            steps: [
                AgentStep(decision: .useTool(name: "mac.calendar.add",
                                             input: "Daughter birthday | today 09:00 | 60"),
                          observation: "Needs your permission first: turn on “Add a calendar event” in Settings → Agent, then try again."),
            ],
            answer: nil,
            haltReason: .needsPermission
        )
        let md = AgentRunExporter.markdown(run, goal: "Add birthday")
        XCTAssertTrue(md.contains("Tools used: Add a calendar event."), "got: \(md)")
        XCTAssertTrue(md.contains("**1. Add a calendar event** — Daughter birthday"), "got: \(md)")
        XCTAssertFalse(md.contains("`mac.calendar.add`"), "raw tool id must not appear in export")
    }
}
