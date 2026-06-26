package ai.quenderin.core

/**
 * Bindable model for the agent loop — the M4 twin of `ChatModel`. The Compose layer maps
 * [onChange] into state, calls [run] off the main thread, and renders [steps] / [answer] /
 * [isRunning]. Streams steps live via the loop's onStep (synchronous here). Mirrors iOS
 * `AgentSession`.
 */
class AgentSession(
    engine: InferenceEngine,
    tools: List<AgentTool>,
    maxSteps: Int = 6,
    var onChange: () -> Unit = {},
) {
    private val loop = AgentLoop(engine, tools, maxSteps)

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
        try {
            steps = emptyList()
            answer = null
            haltReason = null
            onChange()

            val result = loop.run(goal) { step ->
                steps = steps + step
                onChange()
            }

            answer = result.answer
            haltReason = result.haltReason
        } finally {
            isRunning = false
            onChange()
        }
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
