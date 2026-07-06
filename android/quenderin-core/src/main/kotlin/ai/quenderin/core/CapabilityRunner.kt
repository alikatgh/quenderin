package ai.quenderin.core

/**
 * Per-capability consent grants (AGENT_AUTONOMY_PLAN §3.3). Granted BY THE USER in settings —
 * never by code paths reachable from model output, never auto-granted. Twin of iOS `ConsentStore`;
 * the Android app backs it with SharedPreferences, the core ships the in-memory default.
 */
interface ConsentStore {
    fun isGranted(capabilityId: String): Boolean
    fun setGranted(capabilityId: String, granted: Boolean)
}

/** Test/default store — nothing granted until someone grants it. */
class InMemoryConsentStore : ConsentStore {
    private val lock = Any()
    private val granted = mutableSetOf<String>()

    override fun isGranted(capabilityId: String): Boolean = synchronized(lock) { capabilityId in granted }
    override fun setGranted(capabilityId: String, granted: Boolean) {
        synchronized(lock) { if (granted) this.granted.add(capabilityId) else this.granted.remove(capabilityId) }
    }
}

/**
 * The enforcement point (AGENT_AUTONOMY_PLAN §6): every capability invocation goes
 * gate → (refuse | run) → ledger, in that order, with NO path around it. [AgentLoop] calls this
 * instead of `capability.run` directly. Returns the observation the loop feeds back to the model —
 * refusals are worded so the model (and the run log) understand why. Twin of iOS `CapabilityRunner`.
 */
class CapabilityRunner(
    private val consent: ConsentStore = InMemoryConsentStore(),
    private val ledger: AuditLedger = InMemoryAuditLedger(),
    /** Per-RUN approval for MUTATING capabilities (T2+): shown the preview, returns the user's
     *  yes/no. FAIL-CLOSED: null (no approver wired) refuses every mutating action outright.
     *  Consent-in-Settings says "this power may exist"; this says "yes, do THIS one, now". */
    private val approve: ((ActionPreview) -> Boolean)? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    fun execute(capability: Capability, input: String): String {
        fun log(decision: String, outcome: String?) = ledger.append(
            AuditEntry.of(now(), capability.name, capability.tier.ordinal, input, decision, outcome),
        )

        // Twin-drift fix: fail CLOSED if assess()/plan() throws. iOS wraps this in do/catch that ledgers
        // "error" and returns a graceful refusal; Kotlin called it bare, so a throwing plan() escaped
        // execute() with NO ledger row — breaking the fail-closed + flight-recorder invariant.
        val decision = try {
            CapabilityGate.assess(capability, input, consent.isGranted(capability.name))
        } catch (t: Throwable) {
            log("error", t.message)
            return "Couldn't preview ${capability.name}: ${t.message}"
        }
        return when (decision) {
            is GateDecision.Blocked -> {
                log("blocked(${decision.keyword})", null)
                "Refused: touches a blocked action ('${decision.keyword}')."
            }
            is GateDecision.NeedsConsent -> {
                log("needsConsent", null)
                "Needs your permission first: ${decision.preview.summary} Grant \"${capability.name}\" in Settings to allow this."
            }
            is GateDecision.Allowed -> {
                // The write gate: a mutating action needs the user's yes for THIS run, not just a
                // standing grant. No approver wired ⇒ refuse (fail closed), never silently write.
                val preview = decision.preview
                if (preview.mutates) {
                    val approver = approve
                    if (approver == null) {
                        log("needsApproval", null)
                        return "This action changes files and needs your per-run approval, which this surface can't ask for. Not done."
                    }
                    if (!approver(preview)) {
                        log("declined", null)
                        return "You declined: ${preview.summary} Nothing was changed."
                    }
                }
                try {
                    val result = capability.run(input)
                    log("allowed", result)
                    result
                } catch (t: Throwable) {
                    log("error", t.message ?: t.toString())
                    "Tool error: ${t.message}"
                }
            }
        }
    }

    /**
     * Execute a multi-step PLAN with ONE aggregate approval (Milestone 3 — the Cowork UX).
     * All-or-nothing pre-flight: every item blocklist- and consent-checked and previewed BEFORE
     * anything runs; one bad item refuses the whole plan. If any step mutates, the user approves
     * the numbered plan once (fail-closed without an approver). Execution is sequential, each
     * step individually ledgered; a failing step stops the remainder honestly. Twin of iOS.
     */
    fun executePlan(items: List<Pair<Capability, String>>): String {
        fun log(item: Pair<Capability, String>, decision: String, outcome: String?) = ledger.append(
            AuditEntry.of(now(), item.first.name, item.first.tier.ordinal, item.second, decision, outcome),
        )

        // ── Pre-flight every step, before any approval or execution.
        val previews = mutableListOf<ActionPreview>()
        for (item in items) {
            SafetyBlocklist.matches(item.second).firstOrNull()?.let { hit ->
                log(item, "blocked($hit)", null)
                return "Refused: step ${previews.size + 1} touches a blocked action ('$hit'). Nothing was done."
            }
            if (item.first.requiresConsent && !consent.isGranted(item.first.name)) {
                log(item, "needsConsent", null)
                return "Needs your permission first: \"${item.first.name}\" isn't granted in Settings. Nothing was done."
            }
            // Twin-drift fix: a plan() that throws must be a clean nothing-done refusal (fail-closed), not
            // an uncaught exception tearing down the whole agent turn — iOS guards this with `try?`; Kotlin
            // called plan() bare. Ledger "error" and refuse the whole plan, keeping all-or-nothing intact.
            val preview = try {
                item.first.plan(item.second)
            } catch (t: Throwable) {
                log(item, "error", t.message)
                return "Couldn't preview step ${previews.size + 1} (${item.first.name}): ${t.message}. Nothing was done."
            }
            previews.add(preview)
        }

        // ── One aggregate approval when anything writes.
        if (previews.any { it.mutates }) {
            val numbered = previews.mapIndexed { i, p -> "${i + 1}. ${p.summary}" }.joinToString("\n")
            val combined = ActionPreview("The agent proposes this plan:\n$numbered", mutates = true)
            val approver = approve
            if (approver == null) {
                items.forEach { log(it, "needsApproval", null) }
                return "This plan changes files and needs your approval, which this surface can't ask for. Nothing was done."
            }
            if (!approver(combined)) {
                items.forEach { log(it, "declined", null) }
                return "You declined the plan. Nothing was changed."
            }
        }

        // ── Execute sequentially; a failure stops the remainder honestly.
        val results = mutableListOf<String>()
        for ((index, item) in items.withIndex()) {
            try {
                val result = item.first.run(item.second)
                log(item, "allowed", result)
                results.add("${index + 1}. $result")
            } catch (t: Throwable) {
                log(item, "error", t.message ?: t.toString())
                results.add("${index + 1}. Failed: ${t.message}")
                results.add("Stopped after step ${index + 1} of ${items.size}.")
                break
            }
        }
        return results.joinToString("\n")
    }
}
