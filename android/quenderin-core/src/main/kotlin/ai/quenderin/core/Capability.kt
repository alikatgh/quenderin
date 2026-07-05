package ai.quenderin.core

/**
 * The autonomy layer's core abstraction (docs/AGENT_AUTONOMY_PLAN.md §6). A [Capability] is an
 * [AgentTool] that additionally DECLARES its blast radius, so the runtime can gate on the
 * declaration — before ever calling [run] — instead of trusting the tool to behave. Every tool we
 * ship today is pure compute and becomes a T0 capability for free via the interface defaults; a
 * capability must opt UP into risk and can never default into it. Twin of iOS `Capability`.
 * Synchronous here (the core is coroutine-free), matching the AgentTool convention.
 */

/** The risk tier the agent climbs one rung at a time (§4). Ordinal order = risk order. */
enum class CapabilityTier {
    PURE_COMPUTE,     // T0 — no side effects (calculator, unit/date)
    READ_ONLY,        // T1 — reads a resource the user pointed at; nothing written
    REVERSIBLE_WRITE, // T2 — writes that can be undone (scratch file, move-to-trash)
    APP_ACTION,       // T3 — drives an app / fills (not submits) a form
    IRREVERSIBLE,     // T4 — permanent delete, submit; NEVER autonomous
}

/** What a capability's [run] will touch — the runtime reads this to decide consent + preview. */
sealed interface BlastRadius {
    val mutates: Boolean

    data object None : BlastRadius { override val mutates = false }
    data class Read(val resource: String) : BlastRadius { override val mutates = false }
    data class Write(val resource: String) : BlastRadius { override val mutates = true }
    data class Irreversible(val resource: String) : BlastRadius { override val mutates = true }
}

/** A side-effect-free description of what running WOULD do (Shortcuts "read before you run"). */
data class ActionPreview(val summary: String, val mutates: Boolean)

/**
 * An [AgentTool] that declares its risk. Conform an existing pure-compute tool by changing
 * `: AgentTool` to `: Capability` — the T0 defaults apply and behavior is unchanged. Higher
 * tiers override [tier]/[blastRadius]/[plan].
 */
interface Capability : AgentTool {
    val tier: CapabilityTier get() = CapabilityTier.PURE_COMPUTE
    val blastRadius: BlastRadius get() = BlastRadius.None

    /** True when the user must grant this capability before first use (everything above T0). */
    val requiresConsent: Boolean get() = tier > CapabilityTier.PURE_COMPUTE

    /** Preview [run] WITHOUT performing its side effect. Required for T2+; the T0 default says so. */
    fun plan(input: String): ActionPreview =
        ActionPreview("$name: computes locally, no side effects.", mutates = false)
}

/** The ordered pre-flight decision, computed WITHOUT running the capability (§6). */
sealed interface GateDecision {
    data class Blocked(val keyword: String) : GateDecision   // input touches the safety blocklist
    data class NeedsConsent(val preview: ActionPreview) : GateDecision
    data class Allowed(val preview: ActionPreview) : GateDecision
}

/**
 * The safety spine's decision function — PURE, no side effects, no persistence. Composes the
 * (unified) [SafetyBlocklist], the capability's consent requirement, and its preview into the
 * ordered gate from AGENT_AUTONOMY_PLAN §6. The caller executes ONLY on [GateDecision.Allowed].
 * Consent state is passed in; persisting grants is a later Milestone 0 step. Twin of iOS
 * `CapabilityGate`.
 */
object CapabilityGate {
    fun assess(capability: Capability, input: String, isConsented: Boolean): GateDecision {
        // 1. Blocklist first — a blocked action is refused regardless of tier or consent.
        SafetyBlocklist.matches(input).firstOrNull()?.let { return GateDecision.Blocked(it) }
        // 2. Preview (side-effect-free) so the caller can show it in either outcome.
        val preview = capability.plan(input)
        // 3. Consent gate for anything above pure compute.
        if (capability.requiresConsent && !isConsented) return GateDecision.NeedsConsent(preview)
        return GateDecision.Allowed(preview)
    }
}
