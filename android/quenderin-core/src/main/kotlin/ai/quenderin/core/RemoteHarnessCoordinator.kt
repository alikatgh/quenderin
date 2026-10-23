package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str

/** Supplied by a future authenticated native bridge, never inferred from a business packet. */
data class RemoteHarnessAuthenticatedContext(
    val binding: RemoteHarnessTransportBinding, val callerDeviceID: String, val connectionID: String,
    val generation: Long, val sessionID: String? = null,
) {
    constructor(binding: ConversationBinding, callerDeviceID: String, connectionID: String,
        generation: Long, sessionID: String? = null) : this(RemoteHarnessTransportBinding.from(binding),
        callerDeviceID, connectionID, generation, sessionID)
    init {
        rhID(callerDeviceID); rhID(connectionID); sessionID?.let(::rhID)
        rhCheck(generation > 0, "invalid-generation")
        rhCheck(sessionID == null || binding.workspaceID != null, "invalid-binding")
    }
    override fun toString() = "RemoteHarnessAuthenticatedContext(redacted)"
}

interface RemoteHarnessClock {
    fun epochMilliseconds(): Long
    fun monotonicMilliseconds(): Long
}

/** Carries DECRYPTED business JSON only. Implementation must bind callbacks to this exact context.
 * This interface does not establish enrollment, WSS, Noise authentication or interoperability. */
interface RemoteHarnessDecryptedPort {
    fun send(context: RemoteHarnessAuthenticatedContext, frame: ByteArray)
    /** Revoke/close this exact authenticated channel, releasing its Host stream slots. This is
     * mandatory cleanup, not a reconnect or retry. Native adapters must implement channel teardown. */
    fun invalidate(context: RemoteHarnessAuthenticatedContext)
}

class RemoteHarnessPreparedMutation internal constructor(
    val logicalCommandID: String, val wireRequestID: String, val endpoint: String,
    val context: RemoteHarnessAuthenticatedContext,
) {
    override fun toString() = "RemoteHarnessPreparedMutation(redacted)"
}

/** Atomically and durably reserve a previously unused logical command ID BEFORE returning true.
 * Retain its binding and reservation across reconnect/relaunch. A false return/throw must never
 * dispatch. There is no replay API; wire IDs are correlation IDs, not Host deduplication proof. */
fun interface RemoteHarnessMutationJournal {
    fun prepare(command: RemoteHarnessPreparedMutation): Boolean
}

enum class RemoteHarnessOutcomeKind { RESULT, MUTATION_RECEIPT, STOP_RECEIPT, REMOTE_FAILURE, LOCAL_FAILURE, OUTCOME_UNKNOWN }

class RemoteHarnessOutcome internal constructor(
    val kind: RemoteHarnessOutcomeKind, val wireRequestID: String, val logicalCommandID: String?,
    val context: RemoteHarnessAuthenticatedContext,
    val value: RemoteHarnessJSON? = null, val frame: RemoteHarnessFrame? = null, val errorCode: String? = null,
) {
    override fun toString() = "RemoteHarnessOutcome(redacted)"
}

enum class RemoteHarnessStreamNoticeKind { VALUE, CLOSED }
class RemoteHarnessStreamNotice internal constructor(
    val kind: RemoteHarnessStreamNoticeKind, val streamID: String, val context: RemoteHarnessAuthenticatedContext,
    val value: RemoteHarnessJSON? = null, val frame: RemoteHarnessFrame? = null, val reason: String? = null,
) {
    override fun toString() = "RemoteHarnessStreamNotice(redacted)"
}

/** Serialized, thread-safe owner. Zero retries, transfer fallbacks, background jobs or retained
 * transcript queues. Listeners run immediately under the owner monitor and must return promptly.
 * Listener exceptions are contained so an observer cannot strand correlated operations. The caller
 * drives expire() with its bounded scheduler; reconnect requires new authoritative snapshots/streams. */
class RemoteHarnessCoordinator(
    private val port: RemoteHarnessDecryptedPort,
    private val clock: RemoteHarnessClock,
    private val journal: RemoteHarnessMutationJournal,
) {
    private enum class Kind { DESCRIBE, CALL, OPEN, CLOSE }
    private class Pending(val id: String, val context: RemoteHarnessAuthenticatedContext, val kind: Kind, val deadline: Long, val operation: RemoteHarnessOperation?,
        val logicalID: String?, val streamID: String?, val completion: (RemoteHarnessOutcome) -> Unit) { var sent = false }
    private class Stream(val id: String, val context: RemoteHarnessAuthenticatedContext, val operation: RemoteHarnessOperation,
        val listener: (RemoteHarnessStreamNotice) -> Unit)

    private var context: RemoteHarnessAuthenticatedContext? = null
    private var lastGeneration = 0L
    private var nextID = 0L
    private var ready = false
    private var teardownUnconfirmed = false
    private var retiringConnection = false
    private val pending = linkedMapOf<String, Pending>()
    private val streams = linkedMapOf<String, Stream>()
    // A locally removed stream still consumes a Host slot until acknowledged cleanup or teardown.
    private val hostSlots = linkedSetOf<String>()
    private val approvalGate = RemoteHarnessClientApprovalGate(clock)

    @Synchronized fun beginConnection(authenticated: RemoteHarnessAuthenticatedContext) {
        rhCheck(!teardownUnconfirmed, "transport-teardown-unconfirmed")
        rhCheck(!retiringConnection, "connection-retiring")
        rhCheck(authenticated.generation > lastGeneration, "stale-generation")
        terminate("disconnected", authenticated, invalidateTransport = true)
    }

    @Synchronized fun describe(completion: (RemoteHarnessOutcome) -> Unit): String {
        expireLocked(); requireConnected()
        ready = false
        return dispatch(Kind.DESCRIBE, RemoteHarnessCodec.DESCRIBE, obj(), null, null, null, completion)
    }

    @Synchronized fun call(operation: RemoteHarnessOperation, logicalCommandID: String? = operation.logicalCommandID,
        completion: (RemoteHarnessOutcome) -> Unit): String {
        expireLocked(); requireReady(operation)
        rhCheck(!operation.streaming, "invalid-operation")
        // Upstream approval packets lack Host/workspace/run/action/expiry authorization binding.
        rhCheck(operation.endpoint != "\$events/result", "approval-binding-unavailable")
        if (operation.endpoint == RemoteHarnessClientApprovalGate.ENDPOINT) approvalGate.consume(operation, requireConnected())
        if (operation.mutating) {
            rhCheck(logicalCommandID != null, "command-id-required"); rhID(logicalCommandID!!)
            rhCheck(operation.logicalCommandID == null || operation.logicalCommandID == logicalCommandID, "command-id-mismatch")
        } else rhCheck(logicalCommandID == null, "unexpected-command-id")
        return dispatch(Kind.CALL, RemoteHarnessCodec.CALL, operation.params(), operation, logicalCommandID, null, completion)
    }

    @Synchronized fun open(operation: RemoteHarnessOperation, listener: (RemoteHarnessStreamNotice) -> Unit,
        completion: (RemoteHarnessOutcome) -> Unit = {}): String {
        expireLocked(); requireReady(operation)
        rhCheck(operation.streaming, "invalid-operation")
        rhCheck(hostSlots.size < RemoteHarnessBounds.STREAMS, "stream-limit")
        rhCheck(pending.size < RemoteHarnessBounds.PENDING_RPC, "pending-limit")
        val streamID = identifier("stream")
        // Register before send: the Host can deliver a snapshot before settling the open RPC.
        streams[streamID] = Stream(streamID, requireConnected(), operation, listener)
        hostSlots.add(streamID)
        try {
            dispatch(Kind.OPEN, RemoteHarnessCodec.OPEN, operation.params(streamID), operation, null, streamID, completion)
        } catch (error: RemoteHarnessException) {
            hostSlots.remove(streamID) // Dispatch failed before handing an OPEN frame to the port.
            finishStream(streamID, "open-failed"); throw error
        }
        return streamID
    }

    @Synchronized fun closeStream(streamID: String) {
        rhID(streamID)
        val stream = streams.remove(streamID) ?: return
        val opening = pending.values.firstOrNull { it.kind == Kind.OPEN && it.streamID == streamID }
        if (opening != null) { pending.remove(opening.id); deliver(opening, RemoteHarnessOutcomeKind.LOCAL_FAILURE, code = "cancelled") }
        sendClose(streamID, stream.context)
    }

    /** Stale or cross-bound callbacks are ignored before parsing or changing any state. */
    @Synchronized fun receive(authenticated: RemoteHarnessAuthenticatedContext, bytes: ByteArray): Boolean {
        if (context != authenticated) return false
        expireLocked()
        if (context != authenticated) return false
        val frame = RemoteHarnessCodec.decode(bytes)
        if (frame.type == "event") return event(frame, authenticated)
        if (frame.type != "rpc.response" && frame.type != "rpc.error") return false
        val request = pending[frame.requestID] ?: return false
        if (!request.sent) return false
        // Remove exactly once before invoking any listener or possibly reentrant port cleanup.
        pending.remove(request.id)
        val result = frame.payload.values["result"]
        if (frame.type == "rpc.error") {
            // RESPONSE_TOO_LARGE can occur AFTER a Host invokes the mutation. Never replay it.
            val unknown = request.operation?.mutating == true
            completeFailure(request, if (unknown) RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN else RemoteHarnessOutcomeKind.REMOTE_FAILURE,
                frame = frame, code = if (unknown) "mutation-outcome-unknown" else "remote-error")
            return true
        }
        try {
            when (request.kind) {
                Kind.DESCRIBE -> {
                    RemoteHarnessCodec.requireV3(result!!); approvalGate.enable(result); ready = true
                    deliver(request, RemoteHarnessOutcomeKind.RESULT, result, frame)
                }
                Kind.CALL -> {
                    val gateway = RemoteHarnessCodec.gatewayResult(result!!)
                    if (!gateway.ok) deliver(request, RemoteHarnessOutcomeKind.REMOTE_FAILURE, frame = frame, code = "gateway-error")
                    else {
                        val kind = if (request.operation!!.endpoint == "session/cancel") {
                            rhCheck(gateway.value?.objectValue()?.get("accepted")?.booleanValue() == true, "invalid-stop-receipt")
                            RemoteHarnessOutcomeKind.STOP_RECEIPT
                        } else if (request.operation.mutating) RemoteHarnessOutcomeKind.MUTATION_RECEIPT else RemoteHarnessOutcomeKind.RESULT
                        deliver(request, kind, gateway.value, frame)
                    }
                }
                Kind.OPEN, Kind.CLOSE -> {
                    validateStreamAcknowledgement(request, result!!)
                    if (request.kind == Kind.CLOSE) hostSlots.remove(request.streamID)
                    deliver(request, RemoteHarnessOutcomeKind.RESULT, result, frame)
                }
            }
        } catch (_: RemoteHarnessException) {
            completeFailure(request, if (request.operation?.mutating == true) RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN else RemoteHarnessOutcomeKind.LOCAL_FAILURE,
                frame = frame, code = "invalid-response")
        }
        return true
    }

    @Synchronized fun disconnected(authenticated: RemoteHarnessAuthenticatedContext) {
        if (context == authenticated) terminate("disconnected")
    }
    @Synchronized fun expire() = expireLocked()
    @Synchronized fun isReady() = ready
    @Synchronized fun approvalSupported() = approvalGate.available()
    @Synchronized fun pendingApprovals() = approvalGate.approvals()
    @Synchronized fun pendingCount() = pending.size
    @Synchronized fun streamCount() = streams.size
    @Synchronized fun hostSlotCount() = hostSlots.size
    /** A broken adapter teardown blocks this owner; repair the transport before creating a new owner. */
    @Synchronized fun hasUnconfirmedTransportTeardown() = teardownUnconfirmed

    private fun requireConnected() = context ?: throw RemoteHarnessException("disconnected")
    private fun requireReady(operation: RemoteHarnessOperation) {
        val c = requireConnected(); rhCheck(ready, "capabilities-required")
        if (c.binding.workspaceID == null) rhCheck(!operation.mutating && operation.streaming &&
            operation.endpoint == "workspace/follow" && operation.sessionID == null && operation.workspaceID == null,
            "workspace-binding-required")
        rhCheck(operation.sessionID == null || operation.sessionID == c.sessionID, "session-binding-mismatch")
        rhCheck(operation.workspaceID == null || operation.workspaceID == c.binding.workspaceID, "workspace-binding-mismatch")
    }
    private fun identifier(prefix: String): String {
        rhCheck(nextID < Long.MAX_VALUE, "id-exhausted"); nextID++
        return "rh-$lastGeneration-$prefix-$nextID"
    }
    private fun dispatch(kind: Kind, method: String, params: RemoteHarnessJSON, operation: RemoteHarnessOperation?, logicalID: String?,
        streamID: String?, completion: (RemoteHarnessOutcome) -> Unit): String {
        val c = requireConnected()
        rhCheck(pending.size < RemoteHarnessBounds.PENDING_RPC, "pending-limit")
        val now = clock.monotonicMilliseconds()
        rhCheck(now >= 0 && now <= Long.MAX_VALUE - RemoteHarnessBounds.DEADLINE_MS, "invalid-clock")
        val id = identifier("rpc")
        val frame = RemoteHarnessCodec.request(method, params, id, clock.epochMilliseconds())
        val request = Pending(id, c, kind, now + RemoteHarnessBounds.DEADLINE_MS, operation, logicalID, streamID, completion)
        // Reserve capacity before invoking the journal, which may itself call the owner reentrantly.
        pending[id] = request
        if (operation?.mutating == true) {
            val prepared = RemoteHarnessPreparedMutation(logicalID!!, id, operation.endpoint, c)
            val saved = try { journal.prepare(prepared) } catch (_: Exception) { false }
            if (!saved) { pending.remove(id); throw RemoteHarnessException("journal-rejected") }
            // A reentrant journal callback must not swap the connection or expire the reservation.
            if (context != c || pending[id] !== request) { pending.remove(id); throw RemoteHarnessException("connection-changed") }
            if (clock.monotonicMilliseconds() >= request.deadline) { pending.remove(id); throw RemoteHarnessException("deadline-exceeded") }
        }
        request.sent = true
        try { port.send(c, frame.rawJSON.toByteArray(Charsets.UTF_8)) }
        catch (error: Exception) {
            if (pending.remove(id) != null) {
                completeFailure(request, if (operation?.mutating == true) RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN else RemoteHarnessOutcomeKind.LOCAL_FAILURE,
                    code = "send-failed")
            }
            if (error is RemoteHarnessException && error.code == "transport-invalidation-failed") throw error
        }
        return id
    }
    private fun event(frame: RemoteHarnessFrame, authenticated: RemoteHarnessAuthenticatedContext): Boolean {
        val stream = streams[frame.streamID]
        if (stream != null && stream.context != authenticated) return false
        val declaredSession = frame.payload.values["sessionId"]?.stringValue()
        if (declaredSession != null && declaredSession != authenticated.sessionID) return false
        val data = frame.payload.values.rhRequired("data").objectValue()
        if (frame.eventName == RemoteHarnessCodec.STREAM_CLOSED) {
            if (!hostSlots.remove(frame.streamID)) return false
            if (stream != null) {
                streams.remove(stream.id)
                if (stream.operation.endpoint in setOf("workspace/follow", "session/follow", "\$events")) approvalGate.streamClosed()
                notify(stream, RemoteHarnessStreamNotice(RemoteHarnessStreamNoticeKind.CLOSED, stream.id, authenticated, frame = frame, reason = data.rhString("reason")))
            }
        } else {
            if (stream == null) return false
            val value = data["value"]
            val scoped = stream.operation.sessionID
            if (scoped != null && value is RemoteHarnessJSON.ObjectValue) {
                for (key in listOf("sessionId", "agentId")) {
                    val declared = value.values[key] ?: continue
                    if (declared !is RemoteHarnessJSON.StringValue || declared.value != scoped) return false
                }
            }
            approvalGate.observe(stream.operation.endpoint, value, authenticated, frame.timestamp)
            notify(stream, RemoteHarnessStreamNotice(RemoteHarnessStreamNoticeKind.VALUE, stream.id, authenticated, value, frame))
        }
        return true
    }
    private fun expireLocked() {
        val now = clock.monotonicMilliseconds()
        rhCheck(now >= 0, "invalid-clock")
        for (request in pending.values.toList()) {
            if (request.deadline > now || pending.remove(request.id) == null) continue
            completeFailure(request, if (request.sent && request.operation?.mutating == true) RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN else RemoteHarnessOutcomeKind.LOCAL_FAILURE,
                code = "deadline-exceeded")
        }
    }
    /** The request has already left the pending table. Cleanup may fail while tearing down a
     * broken channel; its exception must never bypass this request's exactly-once completion. */
    private fun completeFailure(request: Pending, kind: RemoteHarnessOutcomeKind, frame: RemoteHarnessFrame? = null, code: String) {
        try { failedStreamOperation(request) }
        finally { deliver(request, kind, frame = frame, code = code) }
    }
    private fun validateStreamAcknowledgement(request: Pending, result: RemoteHarnessJSON) {
        val ack = result.objectValue()
        val flag = if (request.kind == Kind.OPEN) "opened" else "closed"
        ack.rhFields(flag, "streamId")
        rhCheck(ack.rhString("streamId") == request.streamID, "stream-ack-mismatch")
        val acknowledged = ack.rhRequired(flag).booleanValue()
        if (request.kind == Kind.OPEN) rhCheck(acknowledged, "stream-open-rejected")
    }
    private fun failedStreamOperation(request: Pending) {
        if (request.kind == Kind.CLOSE) {
            invalidateConnection(request.context, "stream-cleanup-failed")
            return
        }
        if (request.kind != Kind.OPEN) return
        val id = request.streamID ?: return
        finishStream(id, "open-failed")
        sendClose(id, request.context)
    }
    private fun sendClose(streamID: String, expectedContext: RemoteHarnessAuthenticatedContext) {
        if (context != expectedContext || streamID !in hostSlots) return
        if (pending.size >= RemoteHarnessBounds.PENDING_RPC) {
            invalidateConnection(expectedContext, "stream-cleanup-unavailable"); return
        }
        try { dispatch(Kind.CLOSE, RemoteHarnessCodec.CLOSE, obj("streamId" to str(streamID)), null, null, streamID, {}) }
        catch (error: RemoteHarnessException) {
            if (error.code == "transport-invalidation-failed") throw error
            invalidateConnection(expectedContext, "stream-cleanup-unavailable")
        }
    }
    private fun finishStream(streamID: String, reason: String) {
        val stream = streams.remove(streamID) ?: return
        notify(stream, RemoteHarnessStreamNotice(RemoteHarnessStreamNoticeKind.CLOSED, stream.id, stream.context, reason = reason))
    }
    private fun invalidateConnection(expectedContext: RemoteHarnessAuthenticatedContext, reason: String) {
        if (context == expectedContext) terminate(reason, invalidateTransport = true)
    }
    private fun terminate(reason: String, replacement: RemoteHarnessAuthenticatedContext? = null, invalidateTransport: Boolean = false) {
        val oldPending = pending.values.toList(); val oldStreams = streams.values.toList()
        val oldContext = context
        pending.clear(); streams.clear(); hostSlots.clear(); context = null; ready = false
        approvalGate.reset()
        var deliveredReason = reason
        if (invalidateTransport && oldContext != null) {
            retiringConnection = true
            try { port.invalidate(oldContext) } catch (_: Exception) {
                deliveredReason = "transport-invalidation-failed"
                teardownUnconfirmed = true; context = null; ready = false
            } finally { retiringConnection = false }
        }
        // A replacement cannot dispatch (even reentrantly) before old-channel teardown succeeds.
        if (!teardownUnconfirmed) {
            context = replacement
            if (replacement != null) lastGeneration = replacement.generation
        }
        for (request in oldPending) deliver(request,
            if (request.sent && request.operation?.mutating == true) RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN else RemoteHarnessOutcomeKind.LOCAL_FAILURE, code = deliveredReason)
        for (stream in oldStreams) notify(stream, RemoteHarnessStreamNotice(RemoteHarnessStreamNoticeKind.CLOSED, stream.id, stream.context, reason = deliveredReason))
        if (deliveredReason == "transport-invalidation-failed") throw RemoteHarnessException(deliveredReason)
    }
    private fun deliver(request: Pending, kind: RemoteHarnessOutcomeKind, value: RemoteHarnessJSON? = null, frame: RemoteHarnessFrame? = null, code: String? = null) {
        try { request.completion(RemoteHarnessOutcome(kind, request.id, request.logicalID, request.context, value, frame, code)) } catch (_: Exception) { }
    }
    private fun notify(stream: Stream, notice: RemoteHarnessStreamNotice) { try { stream.listener(notice) } catch (_: Exception) { } }
}
