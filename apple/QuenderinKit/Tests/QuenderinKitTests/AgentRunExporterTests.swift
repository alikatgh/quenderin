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
        // Glanceable verification summary up top — outcome + tools used (kept identical to Android).
        XCTAssertTrue(md.contains("**Outcome: answered.** Tools used: calculator."))
        XCTAssertTrue(md.contains("**1. Used `calculator`(2+2)** → 4"))
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
        XCTAssertTrue(md.contains("**Outcome: stopped at the step limit.** Tools used: echo."))
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
        XCTAssertTrue(md.contains("**Outcome: answered.** Tools used: calculator."))   // listed once
    }
}
