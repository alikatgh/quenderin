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
}
