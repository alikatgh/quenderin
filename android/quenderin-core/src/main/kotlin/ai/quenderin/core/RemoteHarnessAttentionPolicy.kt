package ai.quenderin.core

/** Local destination only, never a notification URL or execution authorization. IDs are opaque.
 * Raw event scopes are checked again by the policy; transport construction is not authentication. */
class RemoteHarnessAttentionScope(
    val origin: String, val clientDeviceID: String, val hostID: String, val hostFingerprint: String,
    val workspaceID: String, val sessionID: String,
) {
    constructor(binding: RemoteHarnessTransportBinding, clientDeviceID: String, sessionID: String) :
        this(binding.origin, clientDeviceID, binding.hostID, binding.hostFingerprint,
            binding.workspaceID ?: "", sessionID)
    internal fun components() = listOf(origin, clientDeviceID, hostID, hostFingerprint, workspaceID, sessionID)
    internal fun valid(): Boolean = try {
        rhCheck(origin == ConnectionOrigins.canonicalize(origin), "attention-origin")
        listOf(clientDeviceID, hostID, workspaceID, sessionID).forEach(::rhID)
        rhCheck(Regex("^[a-f0-9]{64}$").matches(hostFingerprint), "attention-pin")
        true
    } catch (_: IllegalArgumentException) { false }
    internal fun exactlyMatches(other: RemoteHarnessAttentionScope) = components() == other.components()
    override fun toString() = "RemoteHarnessAttentionScope(redacted)"
}

/** Future negotiated attention input, supplied ONLY after channel authentication and event validation.
 * No upstream support is inferred from transcript changes. The default rejects unvalidated input.
 * This value deliberately cannot carry a transcript, question, tool arguments, or arbitrary URL. */
class RemoteHarnessAttentionEvent(
    val scope: RemoteHarnessAttentionScope, val generation: Long, val eventID: String, val kind: String,
    val issuedAtEpochMilliseconds: Long, val expiresAtEpochMilliseconds: Long,
    val authenticatedAndNegotiated: Boolean = false, val historical: Boolean = false,
) {
    override fun toString() = "RemoteHarnessAttentionEvent(redacted)"
}

enum class RemoteHarnessAttentionDisposition(val wire: String) { SUPPRESS("suppress"), IN_APP("inApp"), SYSTEM_INTENT("system") }
enum class RemoteHarnessAttentionReason(val wire: String) {
    CLOCK("clock"), UNVALIDATED("unvalidated"), INVALID_SCOPE("invalidScope"), WRONG_DESTINATION("wrongDestination"),
    STALE_GENERATION("staleGeneration"), INVALID_EVENT("invalidEvent"), INVALID_TIME("invalidTime"), EXPIRED("expired"),
    DUPLICATE("duplicate"), CAPACITY("capacity"), HISTORY("history"), DISABLED("disabled"), VIEWED("viewed"), ELIGIBLE("eligible"),
}

/** Generic copy and opaque local routing IDs only. No action or execution capability is exposed. */
class RemoteHarnessAttentionPayload internal constructor(val eventID: String, val sessionID: String) {
    val title = "Remote Harness"
    val body = "A remote session needs your attention."
    override fun toString() = "RemoteHarnessAttentionPayload(redacted)"
}
class RemoteHarnessAttentionDecision internal constructor(
    val disposition: RemoteHarnessAttentionDisposition, val reason: RemoteHarnessAttentionReason,
    val payload: RemoteHarnessAttentionPayload? = null,
) {
    val authorizesExecution: Boolean get() = false
    override fun toString() = "RemoteHarnessAttentionDecision(redacted)"
}

/** Pure opt-in policy, NOT OS push integration: no delivery, registration, permission UI or service.
 * A system intent is only a local result for a future adapter. Even approvals never authorize work.
 * The owner supplies current authenticated scope/generation and both clocks at each evaluation.
 * Keep this owner alive across reconnects; replay memory is process-local, not durable push storage. */
class RemoteHarnessAttentionPolicy {
    private data class Key(val scope: List<String>, val eventID: String)
    private class Entry(val expiresAt: Long, val monotonicDeadline: Long)
    private val remembered = linkedMapOf<Key, Entry>()
    private var lastEpoch: Long? = null
    private var lastMonotonic: Long? = null
    private var lastEffectiveEpoch: Long? = null
    @get:Synchronized val rememberedCount: Int get() = remembered.size

    @Synchronized fun evaluate(
        event: RemoteHarnessAttentionEvent, currentScope: RemoteHarnessAttentionScope, currentGeneration: Long,
        nowEpochMilliseconds: Long, nowMonotonicMilliseconds: Long, enabled: Boolean = false,
        foreground: Boolean, viewedScope: RemoteHarnessAttentionScope? = null,
    ): RemoteHarnessAttentionDecision {
        fun suppress(reason: RemoteHarnessAttentionReason) = RemoteHarnessAttentionDecision(RemoteHarnessAttentionDisposition.SUPPRESS, reason)
        val now = nowEpochMilliseconds; val monotonic = nowMonotonicMilliseconds
        if (now !in 1..RemoteHarnessBounds.SAFE_INTEGER || monotonic !in 0..RemoteHarnessBounds.SAFE_INTEGER ||
            lastEpoch?.let { now < it } == true || lastMonotonic?.let { monotonic < it } == true) return suppress(RemoteHarnessAttentionReason.CLOCK)
        val elapsed = lastMonotonic?.let { monotonic - it } ?: 0L
        val previousEffective = lastEffectiveEpoch ?: now
        if (previousEffective > RemoteHarnessBounds.SAFE_INTEGER - elapsed) return suppress(RemoteHarnessAttentionReason.CLOCK)
        // A frozen/adjusted wall clock cannot extend an event or reopen its expired dedup slot.
        val effectiveNow = maxOf(now, previousEffective + elapsed)
        lastEpoch = now; lastMonotonic = monotonic; lastEffectiveEpoch = effectiveNow
        remembered.entries.removeAll { effectiveNow >= it.value.expiresAt || monotonic >= it.value.monotonicDeadline }
        if (!event.authenticatedAndNegotiated) return suppress(RemoteHarnessAttentionReason.UNVALIDATED)
        if (!event.scope.valid() || !currentScope.valid()) return suppress(RemoteHarnessAttentionReason.INVALID_SCOPE)
        if (!event.scope.exactlyMatches(currentScope)) return suppress(RemoteHarnessAttentionReason.WRONG_DESTINATION)
        if (currentGeneration !in 1..RemoteHarnessBounds.SAFE_INTEGER || event.generation != currentGeneration)
            return suppress(RemoteHarnessAttentionReason.STALE_GENERATION)
        val validID = try { rhID(event.eventID); true } catch (_: IllegalArgumentException) { false }
        if (!validID || event.kind !in KINDS) return suppress(RemoteHarnessAttentionReason.INVALID_EVENT)
        val issued = event.issuedAtEpochMilliseconds; val expires = event.expiresAtEpochMilliseconds
        // Validate bounds/order before subtraction or addition, including near integer limits.
        if (issued !in 1..RemoteHarnessBounds.SAFE_INTEGER || expires !in 1..RemoteHarnessBounds.SAFE_INTEGER ||
            expires <= issued || expires - issued > MAX_EVENT_LIFETIME_MS || issued > now) return suppress(RemoteHarnessAttentionReason.INVALID_TIME)
        if (expires <= effectiveNow) return suppress(RemoteHarnessAttentionReason.EXPIRED)
        val remaining = expires - effectiveNow
        if (monotonic > RemoteHarnessBounds.SAFE_INTEGER - remaining) return suppress(RemoteHarnessAttentionReason.CLOCK)
        val key = Key(event.scope.components(), event.eventID)
        if (key in remembered) return suppress(RemoteHarnessAttentionReason.DUPLICATE)
        if (remembered.size >= MAX_REMEMBERED) return suppress(RemoteHarnessAttentionReason.CAPACITY)
        // Reserve before suppression too: enabling, changing views or reconnecting must not replay it.
        remembered[key] = Entry(expires, monotonic + remaining)
        if (event.historical) return suppress(RemoteHarnessAttentionReason.HISTORY)
        if (!enabled) return suppress(RemoteHarnessAttentionReason.DISABLED)
        if (foreground && viewedScope?.exactlyMatches(event.scope) == true) return suppress(RemoteHarnessAttentionReason.VIEWED)
        return RemoteHarnessAttentionDecision(if (foreground) RemoteHarnessAttentionDisposition.IN_APP else RemoteHarnessAttentionDisposition.SYSTEM_INTENT,
            RemoteHarnessAttentionReason.ELIGIBLE, RemoteHarnessAttentionPayload(event.eventID, event.scope.sessionID))
    }

    override fun toString() = "RemoteHarnessAttentionPolicy(redacted)"
    companion object {
        const val MAX_REMEMBERED = 256
        const val MAX_EVENT_LIFETIME_MS = 600_000L
        private val KINDS = setOf("turn-ended", "failed", "stopped", "approval", "question")
    }
}
