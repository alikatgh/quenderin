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
        XCTAssertTrue(md.contains("**Halted:** The agent reached its step limit"))
        XCTAssertFalse(md.contains("**Answer:**"))
    }
}
