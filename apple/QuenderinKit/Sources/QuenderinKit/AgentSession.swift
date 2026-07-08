import Foundation
import Combine

/// Q-641: a Sendable, thread-safe stop flag shared between the @MainActor session and the loop's
/// `isCancelled` closure. A fresh one is minted per run so a late cancel can't leak into the next.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Bindable model for the agent loop — the M4 twin of `ChatModel`. A SwiftUI view binds
/// to it, calls `run(goal:)`, and renders `steps` / `answer` / `isRunning`. Tools + engine
/// are injected, so it runs on the mock today and on `LlamaEngine` once llama.cpp is linked,
/// with no view changes.
@MainActor
public final class AgentSession: ObservableObject {
    @Published public private(set) var steps: [AgentStep] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var answer: String?
    @Published public private(set) var haltReason: AgentRun.HaltReason?
    /// The matched multi-step recipe for the current run (nil ⇒ the flat run log, exactly today's
    /// behavior). Drives the live checklist header + rows.
    @Published public private(set) var activeRecipe: AgentRecipe?
    /// How many recipe steps have ACTUALLY completed — advanced only on a real executed-tool match,
    /// never a fabricated tick. The checklist ticks against this.
    @Published public private(set) var recipeCursor = 0
    /// Bumped per run so a lagging cross-actor step append from a finished run can't land in the next.
    private var runToken = 0
    /// The goal of the most recent run — kept so the run can be exported with its prompt as the
    /// heading, and so the permission-halt "Allow & run again" affordance can re-run it verbatim.
    public private(set) var lastGoal = ""

    private var loop: AgentLoop
    /// Kept so `cancel()` can interrupt an in-flight decode (Q-641), the way ChatModel holds its engine.
    private let engine: InferenceEngine
    /// The current run's stop flag — a fresh one per run so a late cancel can't leak into the next.
    private var cancelFlag = CancelFlag()

    /// Per-run approvals for mutating capabilities — the view observes `approvals.pending` and
    /// shows an Allow / Don't-allow dialog; the runner awaits the answer.
    public let approvals = ApprovalBroker()

    /// The session's reversible tail (generic undo — mac.* creates etc.). `undoableActions`
    /// mirrors its count for SwiftUI; "Undo task changes" plays it back LIFO.
    public let undoSession = RunSession()
    @Published public private(set) var undoableActions = 0

    public init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                runner: CapabilityRunner? = nil) {
        self.engine = engine
        let broker = approvals
        let resolved = runner ?? CapabilityRunner(approve: { preview in await broker.request(preview) },
                                                  session: undoSession)
        self.loop = AgentLoop(engine: engine, tools: tools, maxSteps: maxSteps, runner: resolved,
                              deliberate: { AgentDeliberation.isEnabled })
    }

    /// Q-641: hard-stop the running mission — interrupt the in-flight decode and flip the run's flag so
    /// the loop ends at its next step boundary with `.cancelled`. No-op when nothing is running. Twin of
    /// the desktop Q-523 kill switch; mirrors `ChatModel.stopGenerating()`.
    public func cancel() {
        guard isRunning else { return }
        cancelFlag.cancel()
        engine.requestCancel()
    }

    /// The app's full wiring: persistent consent (Settings toggles), the on-disk ledger, and
    /// this session's approval dialog. Kept here so QuenderinApp stays one line.
    public convenience init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                            consent: ConsentStore, ledger: AuditLedger) {
        self.init(engine: engine, tools: tools, maxSteps: maxSteps, runner: nil)
        // Rebuild the loop with a runner that has BOTH the stores and this session's approvals.
        let broker = approvals
        let runner = CapabilityRunner(consent: consent, ledger: ledger,
                                      approve: { preview in await broker.request(preview) },
                                      session: undoSession)
        self.loop = AgentLoop(engine: engine, tools: tools, maxSteps: maxSteps, runner: runner,
                              deliberate: { AgentDeliberation.isEnabled })
    }

    /// Run the agent to completion, publishing the result. (The loop also exposes a live
    /// `onStep`; this view-model sets the final transcript, which is enough for the UI and
    /// avoids cross-actor step plumbing — adopt `AsyncStream` later for token-by-token.)
    public func run(goal: String) async {
        // Q-327: reentrancy guard — a second goal submitted while a run is in flight (the `await`
        // below yields the MainActor) would reset `steps`/`answer` out from under the live loop and
        // run two loops at once. Mirror `clear()`'s guard: one run at a time.
        guard !isRunning else { return }
        runToken += 1
        let token = runToken
        lastGoal = goal
        steps = []
        answer = nil
        haltReason = nil
        activeRecipe = nil
        recipeCursor = 0
        isRunning = true
        cancelFlag = CancelFlag()   // Q-641: fresh stop flag for this run
        defer { isRunning = false }

        let flag = cancelFlag
        // Stream live: the loop fires onStep as each step lands and onProgress as the recipe cursor
        // advances. Both hop to the MainActor; the token gate drops a stale append from a prior run.
        // steps come purely from these live appends (== result.steps), so the checklist ticks IN the
        // run, not only after it.
        let result = await loop.run(
            goal: goal,
            onStep: { step in Task { @MainActor [weak self] in
                guard let self, self.runToken == token else { return }
                self.steps.append(step)
            } },
            onProgress: { recipe, cursor in Task { @MainActor [weak self] in
                guard let self, self.runToken == token else { return }
                self.activeRecipe = recipe
                self.recipeCursor = cursor
            } },
            isCancelled: { flag.isCancelled }
        )
        guard runToken == token else { return }   // a newer run started while we awaited
        answer = result.answer
        haltReason = result.haltReason
        undoableActions = undoSession.count   // surface the run's reversible tail to the UI
    }

    /// Reverse everything the LAST task changed (LIFO — the generic trust-loop undo; the
    /// workspace UndoJournal covers file moves separately). Returns the human report.
    public func undoTask() async -> String {
        let report = await undoSession.undoAll()
        undoableActions = 0
        return report
    }

    /// The completed run as a shareable Markdown walkthrough (``AgentRunExporter``), or nil while a run
    /// is in flight or before anything has run. Lets the screen export what the agent did — on the
    /// user's terms, fully on-device — mirroring chat's `ConversationExporter` share.
    public var exportMarkdown: String? {
        guard !isRunning, let reason = haltReason else { return nil }
        return AgentRunExporter.markdown(
            AgentRun(steps: steps, answer: answer, haltReason: reason), goal: lastGoal)
    }

    /// Clear the transcript so the screen returns to its empty state. No-op while a run is in
    /// flight — don't wipe a live run out from under the loop. Mirrors `ChatModel.reset`.
    public func clear() {
        guard !isRunning else { return }
        steps = []
        answer = nil
        haltReason = nil
    }
}
