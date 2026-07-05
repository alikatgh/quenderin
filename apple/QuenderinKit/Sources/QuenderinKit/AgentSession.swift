import Foundation
import Combine

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
    /// The goal of the most recent run — kept so the run can be exported with its prompt as the heading.
    private var lastGoal = ""

    private var loop: AgentLoop

    /// Per-run approvals for mutating capabilities — the view observes `approvals.pending` and
    /// shows an Allow / Don't-allow dialog; the runner awaits the answer.
    public let approvals = ApprovalBroker()

    public init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                runner: CapabilityRunner? = nil) {
        let broker = approvals
        let resolved = runner ?? CapabilityRunner(approve: { preview in await broker.request(preview) })
        self.loop = AgentLoop(engine: engine, tools: tools, maxSteps: maxSteps, runner: resolved)
    }

    /// The app's full wiring: persistent consent (Settings toggles), the on-disk ledger, and
    /// this session's approval dialog. Kept here so QuenderinApp stays one line.
    public convenience init(engine: InferenceEngine, tools: [AgentTool], maxSteps: Int = 6,
                            consent: ConsentStore, ledger: AuditLedger) {
        self.init(engine: engine, tools: tools, maxSteps: maxSteps, runner: nil)
        // Rebuild the loop with a runner that has BOTH the stores and this session's approvals.
        let broker = approvals
        let runner = CapabilityRunner(consent: consent, ledger: ledger,
                                      approve: { preview in await broker.request(preview) })
        self.loop = AgentLoop(engine: engine, tools: tools, maxSteps: maxSteps, runner: runner)
    }

    /// Run the agent to completion, publishing the result. (The loop also exposes a live
    /// `onStep`; this view-model sets the final transcript, which is enough for the UI and
    /// avoids cross-actor step plumbing — adopt `AsyncStream` later for token-by-token.)
    public func run(goal: String) async {
        lastGoal = goal
        steps = []
        answer = nil
        haltReason = nil
        isRunning = true
        defer { isRunning = false }

        let result = await loop.run(goal: goal)
        steps = result.steps
        answer = result.answer
        haltReason = result.haltReason
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
