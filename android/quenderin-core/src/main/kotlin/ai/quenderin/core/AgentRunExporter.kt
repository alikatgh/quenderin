package ai.quenderin.core

/**
 * Renders an [AgentRun] to a portable Markdown **walkthrough** the user can share or save — the
 * agent's reasoning made into a reviewable artifact (the one genuinely transferable idea from agentic
 * IDEs like Google Antigravity: a shareable record of what the agent did and how it concluded), while
 * staying fully on-device. The chat twin is [ConversationExporter]; this is the agent twin. Pure +
 * testable. Twin of Swift `AgentRunExporter`.
 */
object AgentRunExporter {
    fun markdown(run: AgentRun, goal: String): String {
        val heading = goal.trim().takeUnless { it.isEmpty() } ?: "Agent run"
        val n = run.steps.size
        val sb = StringBuilder()
        sb.append("# Agent walkthrough: ").append(heading).append("\n\n")
        sb.append("_Exported from Quenderin — on-device, ").append(n)
            .append(" step").append(if (n == 1) "" else "s").append("._\n\n")

        // A glanceable verification summary up top: the outcome + which tools the agent actually used.
        // Agentic-IDE artifacts (e.g. Google Antigravity) lead with this so a reader can verify the run
        // at a glance instead of reading to the end. ASCII-only + identical wording to the iOS twin.
        val status = when (run.haltReason) {
            AgentRun.HaltReason.ANSWERED -> "answered"
            AgentRun.HaltReason.MAX_STEPS -> "stopped at the step limit"
            AgentRun.HaltReason.BLOCKED -> "stopped by the safety filter"
            AgentRun.HaltReason.PLAN_ERROR -> "stopped (could not form a plan)"
            AgentRun.HaltReason.STALLED -> "stopped (stuck repeating a step)"
            AgentRun.HaltReason.CANCELLED -> "stopped (you halted it)"
            AgentRun.HaltReason.NEEDS_PERMISSION -> "stopped (permission not granted - nothing was done)"
        }
        val toolsUsed = LinkedHashSet<String>()
        run.steps.forEach { step ->
            (step.decision as? AgentDecision.UseTool)?.let { toolsUsed.add(it.name) }
            (step.decision as? AgentDecision.Plan)?.calls?.forEach { toolsUsed.add(it.name) }
        }
        val toolsLine = if (toolsUsed.isEmpty()) "No tools used."
            else "Tools used: " + toolsUsed.joinToString(", ") + "."
        sb.append("**Outcome: ").append(status).append(".** ").append(toolsLine).append("\n\n")

        run.steps.forEachIndexed { i, step ->
            val num = i + 1
            when (val d = step.decision) {
                is AgentDecision.UseTool -> sb.append("**").append(num).append(". Used `")
                    .append(d.name).append("`(").append(d.input).append(")**")
                is AgentDecision.Plan -> sb.append("**").append(num).append(". Proposed a plan:** ")
                    .append(d.calls.joinToString(", ") { "`${it.name}`(${it.input})" })
                is AgentDecision.FinalAnswer -> sb.append("**").append(num).append(". Final answer**")
            }
            step.observation?.takeIf { it.isNotEmpty() }?.let { sb.append(" → ").append(it) }
            sb.append("\n\n")
        }

        // Outcome: the answer when there is one, else the user-facing halt reason (MAX_STEPS/BLOCKED/
        // PLAN_ERROR). ANSWERED returns null from userMessage by design — the answer is shown instead.
        val answer = run.answer
        if (answer != null) {
            sb.append("**Answer:** ").append(answer).append("\n")
        } else {
            run.haltReason.userMessage?.let { sb.append("**Halted:** ").append(it).append("\n") }
        }
        return sb.toString().trim() + "\n"
    }
}
