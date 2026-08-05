package ai.quenderin.app

/**
 * Chat→Agent baton — twin of iOS `AgentHandoff`. Chat posts a goal here; [MainTabs] switches
 * to the Agent tab; [AgentScreen] consumes and runs it. Process-local only (no persistence).
 */
object AgentHandoff {
    @Volatile
    private var pendingGoal: String? = null

    fun send(goal: String) {
        val g = goal.trim()
        if (g.isNotEmpty()) pendingGoal = g
    }

    /** Returns and clears the pending goal, or null if none. */
    fun take(): String? {
        val g = pendingGoal
        pendingGoal = null
        return g
    }

    /** Peek without clearing (tests / diagnostics). */
    fun peek(): String? = pendingGoal
}
