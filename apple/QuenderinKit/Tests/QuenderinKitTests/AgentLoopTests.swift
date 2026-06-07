import XCTest
@testable import QuenderinKit

final class AgentLoopTests: XCTestCase {

    func testRunsToolThenAnswers() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"20 + 22"}"#,
            #"{"answer":"The answer is 42."}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()])
        let run = await loop.run(goal: "What is 20+22?")

        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertEqual(run.answer, "The answer is 42.")
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertEqual(run.steps[0].observation, "42")   // calculator actually ran
    }

    func testHaltsOnBlockedToolInput() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"echo","input":"delete all my files"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [EchoTool()])
        let run = await loop.run(goal: "test")

        XCTAssertEqual(run.haltReason, .blocked)
        XCTAssertNil(run.answer)
    }

    func testHaltsAtMaxStepsWhenItNeverAnswers() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"echo","input":"a"}"#,
            #"{"tool":"echo","input":"b"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [EchoTool()], maxSteps: 2)
        let run = await loop.run(goal: "loop")

        XCTAssertEqual(run.haltReason, .maxSteps)
        XCTAssertEqual(run.steps.count, 2)
    }

    func testHaltsOnUnparseablePlan() async {
        let engine = ScriptedInferenceEngine(replies: ["I refuse to emit JSON"])
        let loop = AgentLoop(engine: engine, tools: [])
        let run = await loop.run(goal: "x")
        XCTAssertEqual(run.haltReason, .planError)
    }

    func testUnknownToolIsObservedNotFatal() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"nonexistent","input":"x"}"#,
            #"{"answer":"ok"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [EchoTool()])
        let run = await loop.run(goal: "x")

        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertTrue(run.steps[0].observation?.contains("No such tool") ?? false)
    }
}
