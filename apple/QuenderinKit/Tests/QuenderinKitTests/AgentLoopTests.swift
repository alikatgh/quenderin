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

    /// The near-miss suggester (live-caught): the model called "mail.draft" for "mac.mail.draft"
    /// and the bare "No such tool" observation left it nothing to recover with. Fixtures kept in
    /// lockstep with the Kotlin twin's CoreVerify check.
    func testUnknownToolMessageSuggestsTheNamespacedTwin() {
        let available = ["calc", "units", "datecalc", "mac.mail.draft", "mac.app.open", "fs.read"]
        let msg = AgentLoop.unknownToolMessage("mail.draft", available: available)
        XCTAssertTrue(msg.contains("No such tool: mail.draft."))
        XCTAssertTrue(msg.contains("Did you mean \"mac.mail.draft\""), "got: \(msg)")
        // A typo within edit distance also recovers.
        XCTAssertTrue(AgentLoop.unknownToolMessage("clac", available: available).contains("\"calc\""))
        // Garbage gets the plain message — no misleading suggestion.
        XCTAssertEqual(AgentLoop.unknownToolMessage("weathersat", available: available),
                       "No such tool: weathersat.")
    }

    /// Reason precedence (live-caught): the model repeated the consent-refused mac.mail.draft —
    /// no other move existed — and the halt was mislabeled "stalled: try rephrasing". When every
    /// attempt was permission-refused, the honest reason is needsPermission however the loop ends.
    func testStallOverRefusedToolReportsNeedsPermissionNotStalled() async {
        let consent = InMemoryConsentStore()   // nothing granted
        let runner = CapabilityRunner(consent: consent, ledger: InMemoryAuditLedger())
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"fs.read","input":"plan.txt"}"#,   // refused (no consent)
            #"{"tool":"fs.read","input":"plan.txt"}"#,   // same again → stall nudge
            #"{"tool":"fs.read","input":"plan.txt"}"#,   // insists → halt
        ])
        let loop = AgentLoop(engine: engine,
                             tools: AgentToolkit.standard(attachments: AttachedFilesStore()),
                             runner: runner)
        let run = await loop.run(goal: "read my plan file")
        XCTAssertEqual(run.haltReason, .needsPermission,
                       "a repeat caused BY a missing grant must say so, not 'try rephrasing'")
    }

    /// Live-caught (the Google-Docs run): the model did an unrelated `calculator` scratchpad call
    /// (a success), THEN got stuck on a consent-refused `mac.safari.openURL`. The old all-attempts
    /// count saw one success + one refusal ≠ all-refused → mislabeled .stalled ("try rephrasing").
    /// Checking the STALLING observation instead correctly reports .needsPermission.
    func testStallOnRefusalAfterAnUnrelatedSuccessReportsNeedsPermission() async {
        let consent = InMemoryConsentStore()   // nothing granted
        let runner = CapabilityRunner(consent: consent, ledger: InMemoryAuditLedger())
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"1"}"#,        // unrelated success (scratchpad)
            #"{"tool":"fs.read","input":"plan.txt"}"#,     // refused — no consent
            #"{"tool":"fs.read","input":"plan.txt"}"#,     // repeat → stall ON the refusal
            #"{"tool":"fs.read","input":"plan.txt"}"#,
        ])
        let loop = AgentLoop(engine: engine,
                             tools: AgentToolkit.standard(attachments: AttachedFilesStore()),
                             runner: runner)
        let run = await loop.run(goal: "compute then read my plan file")
        XCTAssertEqual(run.haltReason, .needsPermission,
                       "stuck on a refusal — even after an unrelated success — is a permission problem")
    }

    /// Zero-action guard (live-caught): the model answered a bare "Done" with an EMPTY run log
    /// on an action goal. One nudge, then an honest halt — never "Done" over no work.
    func testZeroActionAnswerOnAnActionGoalIsNudgedThenWithheld() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"answer":"Done"}"#,          // no action taken — draws the nudge
            #"{"answer":"Done"}"#,          // still no action — withheld
        ])
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()])
        let run = await loop.run(goal: "open browser and write email to i@alink.ru")
        XCTAssertEqual(run.haltReason, .planError)
        XCTAssertNil(run.answer)
        XCTAssertTrue(run.steps.contains { $0.observation?.contains("none were taken") ?? false })
    }

    func testZeroActionNudgeRecoversWhenTheModelThenActs() async {
        let engine = ScriptedInferenceEngine(replies: [
            #"{"answer":"Done"}"#,                       // nudged
            #"{"tool":"calculator","input":"2 + 2"}"#,   // acts
            #"{"answer":"It is 4."}"#,                   // real answer now stands
        ])
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()])
        let run = await loop.run(goal: "open the calculator app and compute 2+2")
        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertEqual(run.answer, "It is 4.")
    }

    func testDirectAnswerOnANonActionGoalIsUntouched() async {
        let engine = ScriptedInferenceEngine(replies: [#"{"answer":"4"}"#])
        let run = await AgentLoop(engine: engine, tools: [CalculatorTool()]).run(goal: "what is 2 plus 2")
        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertEqual(run.answer, "4")
    }

    /// Fabricated-success guard (live-caught on the Mac): every tool attempt was refused for
    /// missing consent — NOTHING executed — yet the model answered "I have drafted the email…".
    /// The loop must not present that lie as the outcome: it halts `.needsPermission`, drops the
    /// fabricated answer, and the banner tells the user exactly how to grant the capability.
    func testFabricatedSuccessAfterConsentRefusalIsWithheld() async {
        let store = AttachedFilesStore()   // nothing attached; fs.read is consent-gated anyway
        let consent = InMemoryConsentStore()               // nothing granted
        let runner = CapabilityRunner(consent: consent, ledger: InMemoryAuditLedger())
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"fs.read","input":"plan.txt"}"#,     // refused: consent not granted
            #"{"answer":"I have read your plan and summarized it."}"#,   // the lie
        ])
        let loop = AgentLoop(engine: engine, tools: AgentToolkit.standard(attachments: store), runner: runner)

        let run = await loop.run(goal: "read my plan")

        XCTAssertEqual(run.haltReason, .needsPermission)
        XCTAssertNil(run.answer, "an answer claiming success after zero executed actions is withheld")
        XCTAssertNotNil(run.haltReason.userMessage)
        XCTAssertTrue(run.steps.contains { $0.observation?.contains("Needs your permission") ?? false })
    }

    /// The guard only fires when NOTHING ran: a mission where a pure tool executed fine keeps
    /// its answer even if a later capability was refused (a partial result is a real result).
    func testPartialExecutionKeepsTheAnswer() async {
        let consent = InMemoryConsentStore()
        let runner = CapabilityRunner(consent: consent, ledger: InMemoryAuditLedger())
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"6 * 7"}"#,                      // executes (pure tool)
            #"{"tool":"fs.read","input":"plan.txt"}"#,                      // refused: no consent
            #"{"answer":"6*7 is 42; I could not read the plan without permission."}"#,
        ])
        let loop = AgentLoop(engine: engine,
                             tools: AgentToolkit.standard(attachments: AttachedFilesStore()),
                             runner: runner)

        let run = await loop.run(goal: "multiply then read")

        XCTAssertEqual(run.haltReason, .answered)
        XCTAssertNotNil(run.answer)
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

    /// Q-641: the loop's hard-stop — a cancelled run halts at the step boundary with `.cancelled`
    /// instead of grinding to maxSteps (the iOS twin of the desktop Q-523 kill switch).
    func testAgentLoopHonorsCancellation() async {
        // Would keep calling the tool forever (never answers) — but cancellation halts it immediately.
        let engine = ScriptedInferenceEngine(replies: [
            #"{"tool":"calculator","input":"1 + 1"}"#,
            #"{"tool":"calculator","input":"2 + 2"}"#,
        ])
        let loop = AgentLoop(engine: engine, tools: [CalculatorTool()], maxSteps: 5)
        let run = await loop.run(goal: "keep going", isCancelled: { true })
        XCTAssertEqual(run.haltReason, .cancelled)
        XCTAssertTrue(run.steps.isEmpty)   // stopped at the first step boundary, before any step ran
    }

    @MainActor
    func testSessionCancelIsNoOpWhenIdle() {
        let engine = ScriptedInferenceEngine(replies: [#"{"answer":"x"}"#])
        let session = AgentSession(engine: engine, tools: [])
        session.cancel()   // nothing running → safe no-op, doesn't wedge anything
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

    /// The agent decode must carry Qwen3's non-thinking sampling recipe (temp 0.7 / top_p 0.8 /
    /// top_k 20) — a verified-SHIP tightening of the tail to the model's tuned distribution. Guards
    /// against a refactor silently reverting to the chat-default top_p 0.95 / no top_k hybrid.
    func testAgentDecodeUsesTheQwen3SamplingRecipe() {
        for opts in [AgentLoop.decisionOptions, AgentLoop.actionFirstOptions] {
            XCTAssertEqual(opts.topK, 20, "agent decode must set top_k=20")
            XCTAssertEqual(opts.topP, 0.8, accuracy: 0.0001, "agent decode must set top_p=0.8")
            XCTAssertEqual(opts.temperature, 0.7, accuracy: 0.0001, "agent decode keeps temp 0.7 (non-thinking)")
            XCTAssertNotNil(opts.gbnfGrammar, "agent decode stays grammar-constrained")
        }
    }

    /// The deliberation (think) decode is the Qwen3 THINKING recipe, UNCONSTRAINED, hard-capped, and
    /// stopped at </think> — the exact shape that lets the model reason without running away.
    func testDeliberationOptionsAreBoundedThinkingRecipe() {
        let o = AgentLoop.deliberationOptions
        XCTAssertNil(o.gbnfGrammar, "the think pass must be unconstrained so the model can actually reason")
        XCTAssertEqual(o.stopSequences, ["</think>"], "must stop at </think> so reasoning can't starve the decision")
        XCTAssertEqual(o.maxTokens, 256, "hard cap keeps latency bounded")
        XCTAssertEqual(o.temperature, 0.6, accuracy: 0.0001)
        XCTAssertEqual(o.topK, 20)
    }

    /// An engine that records the prompts it's asked to complete, to prove the think pass fired.
    private actor RecordingEngine: InferenceEngine {
        private var replies: [String]
        private(set) var prompts: [String] = []
        private var loaded: String? = "rec"
        init(replies: [String]) { self.replies = replies }
        func loadedModelID() async -> String? { loaded }
        func load(model: ModelEntry, at fileURL: URL) async throws { loaded = model.id }
        func unload() async { loaded = nil }
        func generate(prompt: String, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
            prompts.append(prompt)
            let next = replies.isEmpty ? #"{"answer":"done"}"# : replies.removeFirst()
            return AsyncThrowingStream { c in c.yield(next); c.finish() }
        }
    }

    func testDeliberationEnabledRunsAThinkPassAndFeedsItToTheDecision() async {
        let engine = RecordingEngine(replies: ["I should just answer directly", #"{"answer":"42"}"#])
        let loop = AgentLoop(engine: engine, tools: [], deliberate: { true })
        let run = await loop.run(goal: "what is the answer")
        let prompts = await engine.prompts
        XCTAssertEqual(prompts.count, 2, "one think pass + one decision this step")
        XCTAssertTrue(prompts[0].hasSuffix("<think>\n"), "first call is the think pass, seeded with <think>")
        XCTAssertTrue(prompts[1].contains("<think>\nI should just answer directly\n</think>"),
                      "the decision must see the reasoning woven into the transcript")
        XCTAssertEqual(run.answer, "42")
    }

    func testDeliberationOffMakesExactlyOneDecodeWithNoThinkBlock() async {
        let engine = RecordingEngine(replies: [#"{"answer":"42"}"#])
        let loop = AgentLoop(engine: engine, tools: [], deliberate: { false })
        let run = await loop.run(goal: "what is the answer")
        let prompts = await engine.prompts
        XCTAssertEqual(prompts.count, 1, "default off: a single decode, no think pass")
        XCTAssertFalse(prompts[0].contains("<think>"))
        XCTAssertEqual(run.answer, "42")
    }

    // MARK: world-class multi-step — recipes, re-anchor, honest cursor

    private struct FakeTool: AgentTool {
        let name: String
        let purpose = "test tool"
        let reply: String
        func run(_ input: String) async throws -> String { reply }
    }
    private final class CursorRec: @unchecked Sendable { var v: [Int] = []; func add(_ c: Int) { v.append(c) } }

    /// CROWN JEWEL: a generic (non-recipe) goal still gets the goal re-anchored at the transcript tail.
    func testGenericGoalReAnchorsTheGoalAtTheTail() async {
        let engine = RecordingEngine(replies: [#"{"answer":"4"}"#])
        let loop = AgentLoop(engine: engine, tools: [])
        _ = await loop.run(goal: "what is two plus two")
        let prompts = await engine.prompts
        XCTAssertTrue(prompts[0].contains("GOAL (still): what is two plus two"),
                      "the goal must be re-stated at the prompt tail, not just once at the top")
    }

    /// A matched recipe injects its skeleton + names the next step's tool in the re-anchor.
    func testRecipeGoalInjectsSkeletonAndNextStep() async {
        let engine = RecordingEngine(replies: [#"{"answer":"done"}"#])
        let tools: [AgentTool] = [FakeTool(name: "mac.calendar.today", reply: ""),
                                  FakeTool(name: "mac.notes.create", reply: "")]
        let loop = AgentLoop(engine: engine, tools: tools)
        _ = await loop.run(goal: "Make me a prep note for today")
        let prompts = await engine.prompts
        XCTAssertTrue(prompts[0].contains("Morning brief"), "the recipe skeleton must be injected")
        XCTAssertTrue(prompts[0].contains("mac.calendar.today"), "the next step's tool is suggested")
    }

    /// The end-to-end WOW proof: the cursor advances ONLY on real executed-tool matches, in order.
    func testRecipeCursorAdvancesOnRealToolMatchesAndCompletes() async {
        let engine = RecordingEngine(replies: [
            #"{"tool":"mac.calendar.today","input":""}"#,
            #"{"tool":"mac.notes.create","input":"Prep"}"#,
            #"{"answer":"Prep note ready"}"#,
        ])
        let tools: [AgentTool] = [FakeTool(name: "mac.calendar.today", reply: "2 events today"),
                                  FakeTool(name: "mac.notes.create", reply: "Created note.")]
        let rec = CursorRec()
        let loop = AgentLoop(engine: engine, tools: tools)
        let run = await loop.run(goal: "Make me a prep note for today", onProgress: { _, c in rec.add(c) })
        XCTAssertEqual(run.answer, "Prep note ready")
        XCTAssertEqual(rec.v.last, 2, "both recipe steps ticked off, one per real matching tool")
    }

    /// The cursor does NOT advance on a FAILED execution — an honest tick can't fire on a real failure.
    func testRecipeCursorHoldsWhenTheToolFails() async {
        let engine = RecordingEngine(replies: [
            #"{"tool":"mac.calendar.today","input":""}"#,   // fails
            #"{"answer":"giving up"}"#,
        ])
        let tools: [AgentTool] = [FakeTool(name: "mac.calendar.today", reply: "Tool error: boom"),
                                  FakeTool(name: "mac.notes.create", reply: "")]
        let rec = CursorRec()
        let loop = AgentLoop(engine: engine, tools: tools)
        _ = await loop.run(goal: "Make me a prep note for today", onProgress: { _, c in rec.add(c) })
        XCTAssertEqual(rec.v.max() ?? 0, 0, "a failed tool must never tick its step off")
    }

    func testIsFailureObservationIsConservative() {
        XCTAssertTrue(AgentLoop.isFailureObservation("Tool error: whatever"))
        XCTAssertTrue(AgentLoop.isFailureObservation("No such tool: mail.draft"))
        XCTAssertTrue(AgentLoop.isFailureObservation("Mail has no account set up (NO_ACCOUNT)"))
        XCTAssertFalse(AgentLoop.isFailureObservation("No events on your calendar today."), "a valid empty result is NOT a failure")
        XCTAssertFalse(AgentLoop.isFailureObservation("Created note \"Ideas\"."))
    }
}
