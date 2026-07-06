import XCTest
@testable import QuenderinKit

/// Thread-safe sink for the `@Sendable` onStep callback.
private final class StepCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [AgentStep] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return steps.count }
    func add(_ step: AgentStep) { lock.lock(); steps.append(step); lock.unlock() }
}

final class AgentLoopTests: XCTestCase {

    func testStreamsStepsLiveViaOnStep() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"1 + 1"}"#,
            #"{"answer":"done"}"#,
        ])
        let collector = StepCollector()
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()])
        let run = await loop.run(goal: "x") { collector.add($0) }

        // Every step was emitted live, in step with the final transcript.
        XCTAssertEqual(collector.count, run.steps.count)
        XCTAssertEqual(collector.count, 2)
    }

    @MainActor
    func testAgentSessionPublishesResult() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"2 + 2"}"#,
            #"{"answer":"4"}"#,
        ])
        let session = AgentSession(engine: engine, tools: [CalculatorTool()])
        XCTAssertFalse(session.isRunning)

        await session.run(goal: "What is 2+2?")

        XCTAssertEqual(session.answer, "4")
        XCTAssertEqual(session.haltReason, .answered)
        XCTAssertEqual(session.steps.count, 2)
        XCTAssertFalse(session.isRunning)
    }

    /// End-to-end: the SHIPPED export path (loop → session.run → exportMarkdown → AgentRunExporter),
    /// not just the exporter in isolation — catches glue bugs like `lastGoal` not being stored.
    @MainActor
    func testExportMarkdownReflectsTheRealRun() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"2 + 2"}"#,
            #"{"answer":"4"}"#,
        ])
        let session = AgentSession(engine: engine, tools: [CalculatorTool()])
        XCTAssertNil(session.exportMarkdown)   // nothing run yet → nil

        await session.run(goal: "What is 2+2?")

        let md = session.exportMarkdown
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("# Agent walkthrough: What is 2+2?"))   // lastGoal stored + used
        XCTAssertTrue(md!.contains("`calculator`(2 + 2)"))                // the real tool step
        XCTAssertTrue(md!.contains("**Answer:** 4"))                      // the real answer
    }

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

    func testHaltsOnUnparseablePlanAfterConsecutiveFailures() async {
        // A weak model gets ONE corrective nudge; two malformed replies in a row halt planError.
        let engine = ScriptedInferenceEngine(replies: ["I refuse to emit JSON", "still no JSON"])
        let loop = AgentLoop(engine: engine, tools: [])
        let run = await loop.run(goal: "x")
        XCTAssertEqual(run.haltReason, .planError)
    }

    func testRecoversFromOneMalformedReply() async {
        // The nudge lets the model fix its formatting and continue — one slip shouldn't kill the run.
        let engine = ScriptedInferenceEngine(replies: [
            "oops, not JSON",
            #"{"answer":"recovered"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [EchoTool()])
        let run = await loop.run(goal: "x")

        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertEqual(run.answer, "recovered")
    }

    func testHaltsStalledWhenRepeatingTheSameAction() async {
        // A model stuck re-emitting the same tool halts .stalled and runs the side effect only once.
        let same = #"{"tool":"echo","input":"a"}"#
        let engine = ScriptedInferenceEngine(replies: [same, same, same])
        let loop = AgentLoop(engine: engine, tools: [EchoTool()], maxSteps: 6)
        let run = await loop.run(goal: "stuck")

        XCTAssertEqual(run.haltReason, .stalled)
        XCTAssertEqual(run.steps.count, 1)   // executed once; the repeats were nudged, not re-run
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

    // MARK: - Halt-reason user messages (UI surfaces these when there's no answer)

    func testAnsweredHaltHasNoUserMessage() {
        // The answer itself is shown for .answered, so there is no banner message.
        XCTAssertNil(AgentRun.HaltReason.answered.userMessage)
    }

    func testEveryNonAnswerHaltExplainsItself() {
        // Each silent dead-end must give the user a non-empty, distinct reason.
        let reasons: [AgentRun.HaltReason] = [.maxSteps, .blocked, .planError, .stalled]
        let messages = reasons.map { $0.userMessage }
        XCTAssertTrue(messages.allSatisfy { ($0?.isEmpty == false) })
        XCTAssertEqual(Set(messages.compactMap { $0 }).count, reasons.count)
    }

    func testBlockedRunProducesAUserMessage() async {
        // End-to-end: a safety-blocked run halts with a reason the UI can render.
        let engine = ScriptedInferenceEngine(replies: [#"{"tool":"echo","input":"delete all my files"}"#])
        let run = await AgentLoop(engine: engine, tools: [EchoTool()]).run(goal: "test")
        XCTAssertNil(run.answer)
        XCTAssertEqual(run.haltReason.userMessage, AgentRun.HaltReason.blocked.userMessage)
        XCTAssertNotNil(run.haltReason.userMessage)
    }

    @MainActor
    func testClearResetsTheTranscript() async {
        let engine = ScriptedInferenceEngine(replies: [#"{"answer":"done"}"#])
        let session = AgentSession(engine: engine, tools: [])
        await session.run(goal: "x")
        XCTAssertFalse(session.steps.isEmpty)
        XCTAssertEqual(session.answer, "done")

        session.clear()
        XCTAssertTrue(session.steps.isEmpty)
        XCTAssertNil(session.answer)
        XCTAssertNil(session.haltReason)
    }
}
