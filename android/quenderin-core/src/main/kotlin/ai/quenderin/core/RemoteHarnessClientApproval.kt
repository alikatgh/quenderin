package ai.quenderin.core

import java.security.MessageDigest

/** Connection-local evidence from one authoritative durable tool/call, never a request preview. */
class RemoteHarnessClientApprovalAction internal constructor(val toolName: String, val callID: String, val arguments: String) {
    override fun toString() = "RemoteHarnessClientApprovalAction(redacted)"
}

class RemoteHarnessClientApproval internal constructor(
    val binding: RemoteHarnessJSON.ObjectValue, val clientID: String, val request: RemoteHarnessJSON,
    internal val deadline: Long,
) {
    val eventID: String get() = binding.values.rhString("eventId")
    val expiresAt: Long get() = binding.values.rhRequired("expiresAt").integerValue(true)
    override fun toString() = "RemoteHarnessClientApproval(redacted)"
}

/** Owner-thread, connection-local join. The trusted runtime's immutable execution call ID/name
 * associates request metadata with exactly one durable call; transient chunks are never evidence.
 * Conflicting/duplicate calls cannot recover in this turn. No evidence enters saved-state codecs. */
internal class RemoteHarnessClientApprovalActions {
    private data class Key(val session: String, val run: String, val call: String)
    private class Evidence(val sequence: Long, val action: RemoteHarnessClientApprovalAction, val bytes: Int) {
        override fun toString() = "RemoteHarnessClientCallEvidence(redacted)"
    }
    private var session: String? = null
    private var run: String? = null
    private var latestTurn = 0L
    private var blocked = false
    private var bytes = 0
    private val calls = linkedMapOf<Key, Evidence?>()
    fun reset(sessionID: String?) { session = sessionID; run = null; latestTurn = 0; blocked = false; bytes = 0; calls.clear() }
    private fun invalidate() { blocked = true; bytes = 0; calls.clear() }
    fun historyReplaced() = invalidate()
    fun activeTurn(turn: Long) {
        val next = "turn:$turn"
        if (run != next) {
            run = next
            if (turn <= latestTurn) { invalidate(); return }
            latestTurn = turn; blocked = false
            calls.entries.removeAll { (key, value) -> if (key.run != next) { bytes -= value?.bytes ?: 0; true } else false }
        }
    }
    fun observe(sessionID: String?, sequence: Long, type: String, data: Map<String, RemoteHarnessJSON>, advanceRun: Boolean) {
        if (sessionID == null || sessionID != session) { invalidate(); return }
        if (type == "turn/start" && advanceRun) {
            val turn = data.rhRequired("turn").integerValue(true)
            activeTurn(turn)
            return
        }
        if (type == "turn/end" && advanceRun) { run = null; calls.clear(); bytes = 0; blocked = false; return }
        if (type != "tool/call" || blocked) return
        try {
            val call = data.rhString("callId").also(::rhID)
            val callRun = "turn:${data.rhRequired("turn").integerValue(true)}"
            val key = Key(sessionID, callRun, call)
            if (run != null && callRun != run) return
            val name = data.rhString("name").also(::rhID)
            val arguments = data.rhString("arguments")
            val size = arguments.toByteArray(Charsets.UTF_8).size + name.toByteArray(Charsets.UTF_8).size + call.toByteArray(Charsets.UTF_8).size
            rhCheck(arguments.toByteArray(Charsets.UTF_8).size <= 65_536, "approval-action")
            // Validate once on the owner, retaining the exact argument string for review.
            RemoteHarnessJSON.parse(arguments)
            for (scope in listOf("sessionId", "agentId")) data[scope]?.let { rhCheck(it.stringValue() == sessionID, "approval-action") }
            if (calls.containsKey(key)) {
                val previous = calls[key]
                if (previous != null && previous.sequence == sequence && previous.action.toolName == name && previous.action.arguments == arguments) return
                bytes -= previous?.bytes ?: 0; calls[key] = null; return
            }
            rhCheck(calls.size < 128 && bytes + size <= 262_144, "approval-action")
            calls[key] = Evidence(sequence, RemoteHarnessClientApprovalAction(name, call, arguments), size); bytes += size
        } catch (_: RemoteHarnessException) { invalidate() }
    }
    fun resolve(approval: RemoteHarnessClientApproval, sessionID: String?): RemoteHarnessClientApprovalAction? {
        if (blocked || sessionID == null || sessionID != session || run == null) return null
        return try {
            val binding = approval.binding.values; val request = approval.request.objectValue()
            if (binding.rhString("sessionId") != sessionID || binding.rhString("runId") != run) return null
            val call = request.rhString("callId").also(::rhID); val name = request.rhString("toolName").also(::rhID)
            calls[Key(sessionID, run!!, call)]?.action?.takeIf { it.toolName == name }
        } catch (_: RemoteHarnessException) { null }
    }
    fun resolved(approvals: List<RemoteHarnessClientApproval>, sessionID: String?): Map<String, RemoteHarnessClientApprovalAction> =
        java.util.Collections.unmodifiableMap(linkedMapOf<String, RemoteHarnessClientApprovalAction>().apply {
            approvals.forEach { approval -> resolve(approval, sessionID)?.let { put(approval.eventID, it) } }
        })
}

/** Exact extension gate, fed only from correlated authenticated streams. Legacy $events/result
 * remains disabled. Pending rights are connection-local and consumed before command preparation. */
internal class RemoteHarnessClientApprovalGate(private val clock: RemoteHarnessClock) {
    private var enabled = false
    private var clientID: String? = null
    private var run: String? = null
    private var sessionInWorkspace = false
    private val pending = linkedMapOf<String, RemoteHarnessClientApproval>()
    private val seen = linkedSetOf<String>()
    private var lastMonotonic = 0L
    fun enable(value: RemoteHarnessJSON) {
        enabled = (value.objectValue()["capabilities"] as? RemoteHarnessJSON.ArrayValue)?.values
            ?.any { it.stringValue() == CAPABILITY } == true
    }
    fun available() = enabled
    fun reset() { enabled = false; clientID = null; run = null; sessionInWorkspace = false; pending.clear(); seen.clear(); lastMonotonic = 0 }
    fun streamClosed() { pending.clear(); run = null; clientID = null; sessionInWorkspace = false }
    private fun prune(): Long {
        val mono = clock.monotonicMilliseconds()
        rhCheck(mono >= lastMonotonic && mono >= 0, "approval-clock"); lastMonotonic = mono
        pending.entries.removeAll { (_, approval) -> mono >= approval.deadline }
        return mono
    }
    fun approvals(): List<RemoteHarnessClientApproval> { prune(); return pending.values.toList() }
    fun observe(endpoint: String, value: RemoteHarnessJSON?, context: RemoteHarnessAuthenticatedContext, authenticatedHostTimestamp: Long) {
        if (!enabled || value !is RemoteHarnessJSON.ObjectValue) return
        val mono = prune(); val p = value.values
        when (endpoint) {
            "workspace/follow" -> {
                val type = p.rhString("type")
                if (type in setOf("baseline", "replace")) {
                    val items = (p.rhRequired("value").objectValue().rhRequired("items") as? RemoteHarnessJSON.ArrayValue)?.values ?: emptyList()
                    sessionInWorkspace = items.any { workspace -> val w = workspace.objectValue()
                        w.rhString("workspaceId") == context.binding.workspaceID && (w["sessionIds"] as? RemoteHarnessJSON.ArrayValue)?.values
                            ?.any { it.stringValue() == context.sessionID } == true }
                } else if (type == "upsert") {
                    val w = p.rhRequired("workspace").objectValue()
                    if (w.rhString("workspaceId") == context.binding.workspaceID) sessionInWorkspace =
                        (w["sessionIds"] as? RemoteHarnessJSON.ArrayValue)?.values?.any { it.stringValue() == context.sessionID } == true
                } else if (type == "remove" && p.rhString("workspaceId") == context.binding.workspaceID) sessionInWorkspace = false
                if (!sessionInWorkspace) pending.clear()
            }
            "session/follow" -> {
                fun turn(event: RemoteHarnessJSON) {
                    val e = event.objectValue(); val data = e.rhRequired("data").objectValue()
                    if (e.rhString("type") == "turn/start") {
                        val next = "turn:${data.rhRequired("turn").integerValue()}"
                        if (run != next) pending.clear(); run = next
                    } else if (e.rhString("type") == "turn/end") { run = null; pending.clear() }
                }
                if (p.rhString("type") == "snapshot") {
                    run = null; pending.clear()
                    rhCheck(p.rhRequired("header").objectValue().rhString("id") == context.sessionID, "approval-binding")
                    (p["records"] as? RemoteHarnessJSON.ArrayValue)?.values?.forEach { record ->
                        val r = record.objectValue(); if (r.rhString("type") == "event") turn(r.rhRequired("event")) }
                    p["assistantStream"]?.objectValue()?.get("activeAttempt")?.objectValue()?.get("turn")?.let { run = "turn:${it.integerValue()}" }
                } else if (p.rhString("type") == "event") turn(p.rhRequired("event"))
            }
            "\$events" -> when (p.rhString("type")) {
                "ready" -> { pending.clear(); clientID = p.rhString("clientId").also(::rhID) }
                "cancel" -> pending.remove(p.rhString("eventId"))
                "waterfall" -> {
                    if (p.rhString("event") != "approval/request") return
                    val eventID = p.rhString("eventId").also(::rhID)
                    if (eventID in seen) { pending.remove(eventID); return }
                    val binding = p["quenderinBinding"] as? RemoteHarnessJSON.ObjectValue ?: return
                    val b = binding.values
                    validateBinding(b)
                    rhCheck(sessionInWorkspace && clientID != null && p.rhString("agentId") == context.sessionID &&
                        b.rhString("eventId") == eventID && b.rhString("hostDeviceId") == context.binding.hostID &&
                        b.rhString("clientDeviceId") == context.callerDeviceID && b.rhString("workspaceId") == context.binding.workspaceID &&
                        b.rhString("sessionId") == context.sessionID && b.rhString("runId") == run, "approval-binding")
                    // Use the authenticated Host event time to bound the advertised lifetime.
                    // Local wall-clock skew cannot extend or prematurely reject that lifetime.
                    // The Host also enforces its original independent monotonic deadline.
                    val expiry = b.rhRequired("expiresAt").integerValue(true); val remaining = expiry - authenticatedHostTimestamp
                    rhCheck(remaining in 1..120_000 && pending.size < 16 && seen.size < 4096, "approval-expired")
                    val request = p.rhRequired("request")
                    rhCheck(actionDigest(request) == b.rhString("actionDigest"), "approval-action")
                    seen.add(eventID)
                    pending[eventID] = RemoteHarnessClientApproval(binding, clientID!!, request, mono + remaining)
                }
            }
        }
    }
    fun consume(operation: RemoteHarnessOperation, context: RemoteHarnessAuthenticatedContext) {
        prune(); rhCheck(enabled && sessionInWorkspace, "approval-binding-unavailable")
        val args = operation.args.values; val binding = args.rhRequired("binding") as? RemoteHarnessJSON.ObjectValue ?: throw RemoteHarnessException("approval-binding")
        val approval = pending[binding.values.rhString("eventId")] ?: throw RemoteHarnessException("approval-binding")
        rhCheck(RemoteHarnessJSON.write(binding) == RemoteHarnessJSON.write(approval.binding) && args.rhString("clientId") == approval.clientID &&
            binding.values.rhString("runId") == run && binding.values.rhString("sessionId") == context.sessionID &&
            binding.values.rhString("clientDeviceId") == context.callerDeviceID && binding.values.rhString("workspaceId") == context.binding.workspaceID &&
            binding.values.rhString("hostDeviceId") == context.binding.hostID, "approval-binding")
        pending.remove(approval.eventID) // Single-use even if durable preparation or transport fails.
    }
    companion object {
        const val CAPABILITY = "quenderin.approvals.v1"
        const val ENDPOINT = "quenderin/approval"
        fun validateBinding(binding: Map<String, RemoteHarnessJSON>) {
            binding.rhFields("hostDeviceId", "clientDeviceId", "workspaceId", "sessionId", "runId", "eventId", "actionDigest", "expiresAt")
            for (key in listOf("hostDeviceId", "clientDeviceId", "workspaceId", "sessionId", "runId", "eventId")) rhID(binding.rhString(key))
            rhCheck(Regex("^[a-f0-9]{64}$").matches(binding.rhString("actionDigest")), "approval-binding")
            binding.rhRequired("expiresAt").integerValue(true)
        }
        fun actionDigest(value: RemoteHarnessJSON): String {
            rhCheck(RemoteHarnessJSON.write(value).toByteArray(Charsets.UTF_8).size <= 65_536, "approval-action")
            fun arrayIndex(key: String): Long? {
                if (key.isEmpty() || key.length > 10) return null
                val index = key.toLongOrNull() ?: return null
                return index.takeIf { it in 0..4_294_967_294L && it.toString() == key }
            }
            fun canonical(v: RemoteHarnessJSON): RemoteHarnessJSON = when (v) {
                is RemoteHarnessJSON.ObjectValue -> {
                    // JSON.stringify enumerates array-index own properties numerically even
                    // after the Host inserted Object.keys(...).sort() in lexical order.
                    val keys = v.values.keys.sortedWith { left, right ->
                        val l = arrayIndex(left); val r = arrayIndex(right)
                        when { l != null && r != null -> l.compareTo(r); l != null -> -1; r != null -> 1
                            else -> left.compareTo(right) } // Kotlin and JS compare UTF-16 code units.
                    }
                    RemoteHarnessJSON.ObjectValue(linkedMapOf<String, RemoteHarnessJSON>().apply {
                        keys.forEach { key -> put(key, canonical(v.values.getValue(key))) }
                    })
                }
                is RemoteHarnessJSON.ArrayValue -> RemoteHarnessJSON.ArrayValue(v.values.map(::canonical))
                is RemoteHarnessJSON.NumberValue -> {
                    // The Host parsed JSON numbers as IEEE-754 values before hashing. Retaining
                    // input lexemes (1.0, -0, 1.0000000000000001) would hash a different action.
                    rhCheck(v.token.length <= 128, "approval-action")
                    val n = v.token.toDoubleOrNull() ?: throw RemoteHarnessException("approval-action")
                    rhCheck(n.isFinite() && kotlin.math.abs(n) <= 9_007_199_254_740_991.0 &&
                        (n == 0.0 || kotlin.math.abs(n) >= 0.000001), "approval-action")
                    RemoteHarnessJSON.NumberValue(java.math.BigDecimal.valueOf(n).stripTrailingZeros().toPlainString())
                }
                else -> v
            }
            val encoded = RemoteHarnessJSON.write(canonical(value)).toByteArray(Charsets.UTF_8)
            rhCheck(encoded.size <= 65_536, "approval-action")
            return MessageDigest.getInstance("SHA-256").digest(encoded).joinToString("") { "%02x".format(it.toInt() and 255) }
        }
    }
}
