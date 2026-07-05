package ai.quenderin.core

/** One turn of the agent: what it decided, and what it observed (tool output, a refusal,
 *  or null for a final answer). */
data class AgentStep(val decision: AgentDecision, val observation: String?)

/** The result of running the agent to completion. */
data class AgentRun(val steps: List<AgentStep>, val answer: String?, val haltReason: HaltReason) {
    enum class HaltReason { ANSWERED, MAX_STEPS, BLOCKED, PLAN_ERROR }
}

/**
 * A short, user-facing explanation for why the agent stopped, shown when there is no answer
 * to display. ANSWERED returns null — the answer itself is shown instead. Kept identical to
 * iOS `AgentRun.HaltReason.userMessage` (cross-platform parity).
 */
val AgentRun.HaltReason.userMessage: String?
    get() = when (this) {
        AgentRun.HaltReason.ANSWERED -> null
        AgentRun.HaltReason.MAX_STEPS -> "The agent reached its step limit before reaching an answer. Try a simpler or more specific goal."
        AgentRun.HaltReason.BLOCKED -> "The agent stopped: a step was blocked by the on-device safety filter."
        AgentRun.HaltReason.PLAN_ERROR -> "The agent couldn't work out a step-by-step plan for that goal."
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
    /** The enforcement point for tools that are [Capability]s: gate → run → ledger, no way
     *  around it (AGENT_AUTONOMY_PLAN §6). Plain [AgentTool]s keep the legacy direct path. */
    private val runner: CapabilityRunner = CapabilityRunner(),
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
                is AgentDecision.Plan -> {
                    // Safety gate per step, BEFORE anything runs — a plan containing a blocked
                    // action is a bad plan, not a plan to trim.
                    if (decision.calls.any { SafetyBlocklist.isBlocked(it.input) || SafetyBlocklist.isBlocked(it.name) }) {
                        record(AgentStep(decision, "Refused: the plan touches a blocked action."))
                        return AgentRun(steps, null, AgentRun.HaltReason.BLOCKED)
                    }
                    // Every step must resolve to a Capability — the runner's plan path owns
                    // consent + the ONE aggregate approval + per-step ledgering.
                    val resolved = mutableListOf<Pair<Capability, String>>()
                    var unknown: String? = null
                    for (call in decision.calls) {
                        val capability = tools.firstOrNull { it.name == call.name } as? Capability
                        if (capability == null) { unknown = call.name; break }
                        resolved.add(capability to call.input)
                    }
                    val observation = if (unknown != null) "No such tool: $unknown. Plan not executed."
                    else runner.executePlan(resolved)
                    record(AgentStep(decision, observation))
                    val described = decision.calls.joinToString(", ") { "${it.name}(${it.input})" }
                    transcript += "\nProposed plan [$described] → $observation"
                }
            }
        }
        return AgentRun(steps, null, AgentRun.HaltReason.MAX_STEPS)
    }

    private fun execute(name: String, input: String): String {
        val tool = tools.firstOrNull { it.name == name } ?: return "No such tool: $name."
        // Capabilities go through the runner (blocklist → consent → preview → run → ledger);
        // for T0 tools the observable behavior is identical, plus the ledger row.
        if (tool is Capability) return runner.execute(tool, input)
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
            Respond with ONE JSON object: {"tool":"<name>","input":"<text>"} to use a tool, {"plan":[{"tool":"<name>","input":"<text>"},…]} to propose several steps the user approves together, or {"answer":"<final answer>"} when done.
        """.trimIndent()
    }
}
