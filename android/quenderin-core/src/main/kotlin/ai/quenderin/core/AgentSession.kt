package ai.quenderin.core

/**
 * Bindable model for the agent loop — the M4 twin of `ChatModel`. The Compose layer maps
 * [onChange] into state, calls [run] off the main thread, and renders [steps] / [answer] /
 * [isRunning]. Streams steps live via the loop's onStep (synchronous here). Mirrors iOS
 * `AgentSession`.
 */
class AgentSession(
    private val engine: InferenceEngine,
    tools: List<AgentTool>,
    maxSteps: Int = 6,
    /** The app's full governance wiring (persistent consent, on-disk ledger, the approval
     *  dialog's broker). Null keeps the bare fail-closed default. Twin of the iOS
     *  AgentSession runner injection. NB: `onChange` stays LAST so existing trailing-lambda
     *  callers (`AgentSession(engine, tools) { … }`) still bind to it — the AgentLoop lesson. */
    runner: CapabilityRunner? = null,
    /** Opt-in "think, then decide" — read LIVE (the Settings toggle) so it takes effect on the next run.
     *  Off by default. Twin of iOS AgentSession reading `AgentDeliberation.isEnabled`. Placed before
     *  `onChange` so the trailing-lambda callers still bind onChange (same rule as `runner`). */
    deliberate: () -> Boolean = { false },
    var onChange: () -> Unit = {},
) {
    private val loop =
        if (runner != null) AgentLoop(engine, tools, maxSteps, runner, deliberate)
        else AgentLoop(engine, tools, maxSteps, deliberate = deliberate)

    /** Q-641: the current run's stop flag. cancel() flips it (and interrupts the in-flight decode); the
     *  loop checks it each step boundary and halts with CANCELLED. @Volatile — cancel() may run on the
     *  main thread while the loop runs off-main. Twin of iOS AgentSession.cancel() / desktop Q-523. */
    @Volatile
    private var cancelRequested = false

    @Volatile
    var steps: List<AgentStep> = emptyList()
        private set

    @Volatile
    var isRunning: Boolean = false
        private set

    @Volatile
    var answer: String? = null
        private set

    @Volatile
    var haltReason: AgentRun.HaltReason? = null
        private set

    /** Goal of the most recent run — kept (volatile, for the main-thread Compose reader) so the run can
     *  be exported with its prompt as the heading. */
    @Volatile
    private var lastGoal: String = ""

    /**
     * The completed run as a shareable Markdown walkthrough ([AgentRunExporter]), or null while a run is
     * in flight or before anything has run. Lets the screen export what the agent did — on the user's
     * terms, fully on-device — mirroring chat's ConversationExporter share. Twin of iOS `exportMarkdown`.
     */
    fun exportMarkdown(): String? {
        val reason = haltReason ?: return null
        if (isRunning) return null
        return AgentRunExporter.markdown(AgentRun(steps, answer, reason), lastGoal)
    }

    /**
     * Run the agent to completion. Blocking; call off-main. Streams steps live.
     * Fields are @Volatile so the Compose reader on the main thread sees the background writes
     * (happens-before), and run() is guarded against re-entry — concurrent runs would race
     * destructively. isRunning is cleared in finally so a throw can't leave it stuck (M10).
     */
    fun run(goal: String) {
        synchronized(this) {
            if (isRunning) return
            isRunning = true
        }
        lastGoal = goal
        cancelRequested = false   // Q-641: fresh per run
        try {
            steps = emptyList()
            answer = null
            haltReason = null
            onChange()

            val result = loop.run(
                goal,
                onStep = { step -> steps = steps + step; onChange() },
                isCancelled = { cancelRequested },
            )

            answer = result.answer
            haltReason = result.haltReason
        } finally {
            isRunning = false
            onChange()
        }
    }

    /**
     * Q-641: hard-stop the running mission — interrupt the in-flight decode and flip the flag so the loop
     * ends at its next step boundary with CANCELLED. No-op when nothing is running. Twin of iOS
     * `AgentSession.cancel()` / the desktop Q-523 kill switch.
     */
    fun cancel() {
        if (!isRunning) return
        cancelRequested = true
        engine.requestCancel()
    }

    /**
     * Clear the transcript so the screen returns to its empty state. No-op while a run is in
     * flight — don't wipe a live run out from under the loop. Mirrors iOS `AgentSession.clear`.
     */
    fun clear() {
        synchronized(this) { if (isRunning) return }
        steps = emptyList()
        answer = null
        haltReason = null
        onChange()
    }
}
