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

        return when (val decision = CapabilityGate.assess(capability, input, consent.isGranted(capability.name))) {
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
}
