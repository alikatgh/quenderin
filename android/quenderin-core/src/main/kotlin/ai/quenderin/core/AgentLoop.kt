package ai.quenderin.core

/** One turn of the agent: what it decided, and what it observed (tool output, a refusal,
 *  or null for a final answer). */
data class AgentStep(val decision: AgentDecision, val observation: String?)

/** The result of running the agent to completion. */
data class AgentRun(val steps: List<AgentStep>, val answer: String?, val haltReason: HaltReason) {
    enum class HaltReason { ANSWERED, MAX_STEPS, BLOCKED, PLAN_ERROR, STALLED, CANCELLED, NEEDS_PERMISSION }
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
        AgentRun.HaltReason.STALLED -> "The agent got stuck repeating the same step. Try rephrasing the goal."
        AgentRun.HaltReason.CANCELLED -> "Stopped — you halted the agent."
        AgentRun.HaltReason.NEEDS_PERMISSION -> "The agent needs your permission for the tools it planned — nothing was done yet. Grant the capability named in the run log (Settings → Agent), then run the goal again."
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

    // NB: `onStep` stays LAST so existing `run(goal) { … }` trailing-lambda calls still bind to it
    // (Kotlin binds a trailing lambda to the last param — no Swift-style forward scan).
    fun run(goal: String, isCancelled: () -> Boolean = { false }, onStep: (AgentStep) -> Unit = {}): AgentRun {
        val steps = mutableListOf<AgentStep>()
        var transcript = preamble(goal)
        // Reliability guards for a weak on-device model (twins of the desktop CapabilityAgent):
        // `parseFailures` recovers from malformed JSON (nudge + retry, not instant death); `stall`
        // catches the model re-emitting the SAME action (nudge, then halt STALLED). Both nudge the
        // transcript only — a nudge isn't a step the agent took.
        var prevSig: String? = null
        var lastObs = ""
        var stall = 0
        var parseFailures = 0
        // Fabricated-success guard (live-caught on the Mac twin): a consent-refused tool call
        // executes NOTHING, but a small model then answers "I have drafted the email…" — a fluent
        // lie about an action that never happened. If the model claims done while every attempt
        // was a permission refusal, halt NEEDS_PERMISSION instead of presenting the fabrication.
        var toolAttempts = 0
        var refusedAttempts = 0

        fun record(step: AgentStep) {
            steps.add(step)
            onStep(step)   // live update for the UI, as each step happens
        }

        repeat(maxSteps) {
            // Q-641: hard-stop (kill switch) — checked at each step boundary so AgentSession.cancel()
            // ends the mission with CANCELLED instead of grinding to maxSteps. Twin of iOS / desktop Q-523.
            if (isCancelled()) return AgentRun(steps, null, AgentRun.HaltReason.CANCELLED)
            val reply = try {
                engine.complete(transcript)
            } catch (t: Throwable) {
                return AgentRun(steps, null, AgentRun.HaltReason.PLAN_ERROR)
            }
            val decision = AgentDecisionParser.parse(reply)
            if (decision == null) {
                // Malformed output: nudge with the contract and retry; halt only if it slips again.
                parseFailures++
                if (parseFailures >= 2) return AgentRun(steps, null, AgentRun.HaltReason.PLAN_ERROR)
                transcript += "\n" + PARSE_NUDGE
                return@repeat
            }
            parseFailures = 0

            // A final answer has no action to repeat — handle (and safety-gate, H14) before the guard.
            if (decision is AgentDecision.FinalAnswer) {
                if (SafetyBlocklist.isBlocked(decision.answer)) {
                    record(AgentStep(decision, "Refused: answer touches a blocked topic."))
                    return AgentRun(steps, null, AgentRun.HaltReason.BLOCKED)
                }
                // Every tool attempt was refused for missing permission ⇒ NOTHING executed, so any
                // answer implying the task happened is false. Drop it and say what's actually true.
                if (toolAttempts > 0 && refusedAttempts == toolAttempts) {
                    record(AgentStep(decision, "The answer was withheld: no tool actually ran (permission was missing)."))
                    return AgentRun(steps, null, AgentRun.HaltReason.NEEDS_PERMISSION)
                }
                record(AgentStep(decision, null))
                return AgentRun(steps, decision.answer, AgentRun.HaltReason.ANSWERED)
            }

            // Stuck detection: the model re-proposed the exact action it just ran. Don't re-execute
            // (that repeats side effects / re-fails identically) — nudge, and bail if it insists.
            val sig = signatureOf(decision)
            if (sig == prevSig) {
                stall++
                if (stall >= 2) return AgentRun(steps, null, AgentRun.HaltReason.STALLED)
                transcript += "\nYou already ran $sig and got: $lastObs — do something different, or reply {\"answer\":\"…\"} if the task is done."
                return@repeat
            }
            stall = 0

            val observation: String = when (decision) {
                is AgentDecision.FinalAnswer -> ""   // unreachable — handled above
                is AgentDecision.UseTool -> {
                    // Safety gate — refuse blocked actions before they ever run.
                    if (SafetyBlocklist.isBlocked(decision.input) || SafetyBlocklist.isBlocked(decision.name)) {
                        record(AgentStep(decision, "Refused: touches a blocked action."))
                        return AgentRun(steps, null, AgentRun.HaltReason.BLOCKED)
                    }
                    val obs = execute(decision.name, decision.input)
                    toolAttempts++
                    if (isPermissionRefusal(obs)) refusedAttempts++
                    transcript += "\nUsed ${decision.name}(${decision.input}) → $obs"
                    obs
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
                    val obs = if (unknown != null) "No such tool: $unknown. Plan not executed."
                    else runner.executePlan(resolved)
                    val described = decision.calls.joinToString(", ") { "${it.name}(${it.input})" }
                    transcript += "\nProposed plan [$described] → $obs"
                    obs
                }
            }

            record(AgentStep(decision, observation))
            prevSig = sig
            lastObs = observation
        }
        return AgentRun(steps, null, AgentRun.HaltReason.MAX_STEPS)
    }

    /** A stable fingerprint of an action, so the loop can spot the model re-proposing the same thing. */
    private fun signatureOf(decision: AgentDecision): String = when (decision) {
        is AgentDecision.FinalAnswer -> "answer"
        is AgentDecision.UseTool -> "${decision.name}(${decision.input})"
        is AgentDecision.Plan -> "plan[" + decision.calls.joinToString(", ") { "${it.name}(${it.input})" } + "]"
    }

    private companion object {
        /** The corrective nudge shown after a malformed reply — the exact JSON contract, once. */
        const val PARSE_NUDGE = "Your last reply was not valid JSON. Reply with EXACTLY ONE JSON object and nothing else: {\"tool\":\"<name>\",\"input\":\"<text>\"}, {\"plan\":[{\"tool\":\"<name>\",\"input\":\"<text>\"},…]}, or {\"answer\":\"<text>\"}."

        /**
         * True when a tool observation means the action did NOT execute for lack of the user's
         * permission. These prefixes are OUR OWN stable strings from [CapabilityRunner] — not
         * model output. Kept in lockstep with the Swift twin's `isPermissionRefusal`.
         */
        fun isPermissionRefusal(observation: String): Boolean =
            observation.startsWith("Needs your permission first:") ||
                observation.startsWith("You declined:") ||
                observation.startsWith("This action changes files and needs your per-run approval")
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
