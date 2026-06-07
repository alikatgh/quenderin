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

    var steps: List<AgentStep> = emptyList()
        private set
    var isRunning: Boolean = false
        private set
    var answer: String? = null
        private set
    var haltReason: AgentRun.HaltReason? = null
        private set

    /** Run the agent to completion. Blocking; call off-main. Streams steps live. */
    fun run(goal: String) {
        steps = emptyList()
        answer = null
        haltReason = null
        isRunning = true
        onChange()

        val result = loop.run(goal) { step ->
            steps = steps + step
            onChange()
        }

        answer = result.answer
        haltReason = result.haltReason
        isRunning = false
        onChange()
    }
}
