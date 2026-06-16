package ai.quenderin.core

/** One turn of the agent: what it decided, and what it observed (tool output, a refusal,
 *  or null for a final answer). */
data class AgentStep(val decision: AgentDecision, val observation: String?)

/** The result of running the agent to completion. */
data class AgentRun(val steps: List<AgentStep>, val answer: String?, val haltReason: HaltReason) {
    enum class HaltReason { ANSWERED, MAX_STEPS, BLOCKED, PLAN_ERROR }
}

/**
 * The vision's perceive → plan → execute loop, in the shippable form: a **tool-use** agent.
 * Each turn the planner (an [InferenceEngine]) emits a decision; tool calls are
 * **safety-gated** ([SafetyBlocklist]) before running, their output is fed back, and the
 * loop repeats until a final answer or a step cap. Pure logic over the seams — fully
 * testable with [ScriptedInferenceEngine]. Mirrors iOS `AgentLoop`.
 */
class AgentLoop(
    private val engine: InferenceEngine,
    private val tools: List<AgentTool>,
    maxSteps: Int = 6,
) {
    private val maxSteps = maxOf(1, maxSteps)

    fun run(goal: String, onStep: (AgentStep) -> Unit = {}): AgentRun {
        val steps = mutableListOf<AgentStep>()
        var transcript = preamble(goal)

        fun record(step: AgentStep) {
            steps.add(step)
            onStep(step)   // live update for the UI, as each step happens
        }

        repeat(maxSteps) {
            val reply = try {
                engine.complete(transcript)
            } catch (t: Throwable) {
                return AgentRun(steps, null, AgentRun.HaltReason.PLAN_ERROR)
            }
            val decision = AgentDecisionParser.parse(reply)
                ?: return AgentRun(steps, null, AgentRun.HaltReason.PLAN_ERROR)

            when (decision) {
                is AgentDecision.FinalAnswer -> {
                    // The safety gate also applies to the final answer (H14): a jailbroken/fine-tuned
                    // on-device model could emit blocked content as an answer, bypassing the tool-only gate.
                    if (SafetyBlocklist.isBlocked(decision.answer)) {
                        record(AgentStep(decision, "Refused: answer touches a blocked topic."))
                        return AgentRun(steps, null, AgentRun.HaltReason.BLOCKED)
                    }
                    record(AgentStep(decision, null))
                    return AgentRun(steps, decision.answer, AgentRun.HaltReason.ANSWERED)
                }
                is AgentDecision.UseTool -> {
                    // Safety gate — refuse blocked actions before they ever run.
                    if (SafetyBlocklist.isBlocked(decision.input) || SafetyBlocklist.isBlocked(decision.name)) {
                        record(AgentStep(decision, "Refused: touches a blocked action."))
                        return AgentRun(steps, null, AgentRun.HaltReason.BLOCKED)
                    }
                    val observation = execute(decision.name, decision.input)
                    record(AgentStep(decision, observation))
                    transcript += "\nUsed ${decision.name}(${decision.input}) → $observation"
                }
            }
        }
        return AgentRun(steps, null, AgentRun.HaltReason.MAX_STEPS)
    }

    private fun execute(name: String, input: String): String {
        val tool = tools.firstOrNull { it.name == name } ?: return "No such tool: $name."
        return try {
            tool.run(input)
        } catch (t: Throwable) {
            "Tool error: ${t.message}"
        }
    }

    private fun preamble(goal: String): String {
        val toolList = tools.joinToString("\n") { "- ${it.name}: ${it.purpose}" }
        return """
            Goal: $goal
            Available tools:
            $toolList
            Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use a tool, or {"answer":"<final answer>"} when done.
        """.trimIndent()
    }
}
