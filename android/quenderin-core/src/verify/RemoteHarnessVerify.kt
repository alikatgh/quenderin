package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.io.File

private fun rhCanonical(value: RemoteHarnessJSON): String {
    fun ordered(v: RemoteHarnessJSON): RemoteHarnessJSON = when (v) {
        is RemoteHarnessJSON.ObjectValue -> RemoteHarnessJSON.ObjectValue(v.values.toSortedMap().mapValues { ordered(it.value) })
        is RemoteHarnessJSON.ArrayValue -> RemoteHarnessJSON.ArrayValue(v.values.map(::ordered))
        else -> v
    }
    return RemoteHarnessJSON.write(ordered(value))
}
private fun rhRejected(code: String? = null, block: () -> Unit) {
    val error = try { block(); null } catch (error: RemoteHarnessException) { error }
    check(error != null && (code == null || error.code == code))
}
private fun connectionRejected(code: String, block: () -> Unit) {
    val error = try { block(); null } catch (error: NativeConnectionException) { error }
    check(error?.code == code)
}
private class HarnessFakeClock : RemoteHarnessClock {
    var now = 1L
    override fun epochMilliseconds() = now
    override fun monotonicMilliseconds() = now
}
private class HarnessFakeJournal : RemoteHarnessMutationJournal {
    val commands = arrayListOf<RemoteHarnessPreparedMutation>()
    val ids = mutableSetOf<String>()
    var reject = false
    var throwing = false
    var onPrepare: ((RemoteHarnessPreparedMutation) -> Unit)? = null
    override fun prepare(command: RemoteHarnessPreparedMutation): Boolean {
        if (throwing) error("private journal failure")
        if (reject || !ids.add(command.logicalCommandID)) return false
        commands.add(command); onPrepare?.invoke(command); return true
    }
}
private class HarnessFake(initialContext: RemoteHarnessAuthenticatedContext = RemoteHarnessAuthenticatedContext(
    ConversationBinding.create("remote", ConnectionKind.REMOTE_HARNESS,
        "https://relay.example", "host-a", "a".repeat(64), "workspace-a"), "device-a", "connection-a", 1, "session-a")) {
    val clock = HarnessFakeClock()
    val journal = HarnessFakeJournal()
    var context = initialContext
    val sent = arrayListOf<RemoteHarnessFrame>()
    val invalidated = arrayListOf<RemoteHarnessAuthenticatedContext>()
    val hostSlots = linkedSetOf<String>()
    var invalidateThrows = false
    var onInvalidate: (() -> Unit)? = null
    var onSend: ((RemoteHarnessFrame) -> Unit)? = null
    val owner = RemoteHarnessCoordinator(object : RemoteHarnessDecryptedPort {
        override fun send(authenticated: RemoteHarnessAuthenticatedContext, bytes: ByteArray) {
            check(authenticated == context)
            val frame = RemoteHarnessCodec.decode(bytes); sent.add(frame)
            val method = frame.payload.values.rhString("method")
            if (method == RemoteHarnessCodec.OPEN) hostSlots.add(frame.payload.values.rhRequired("params").objectValue().rhString("streamId"))
            if (method == RemoteHarnessCodec.DESCRIBE) {
                reply(frame.id, obj("capabilities" to RemoteHarnessJSON.ArrayValue(listOf(str("harness.remote.v3")))))
            } else onSend?.invoke(frame)
        }
        override fun invalidate(context: RemoteHarnessAuthenticatedContext) {
            invalidated.add(context)
            onInvalidate?.invoke()
            if (invalidateThrows) error("private adapter teardown failure")
            hostSlots.clear()
        }
    }, clock, journal)
    init { owner.beginConnection(context) }
    fun ready() { owner.describe {}; check(owner.isReady()) }
    fun frame(type: String, payload: RemoteHarnessJSON, id: String = "host-${sent.size}-${clock.now}") = RemoteHarnessJSON.write(
        obj("v" to num(1), "id" to str(id), "type" to str(type), "timestamp" to num(clock.now), "payload" to payload)).toByteArray(Charsets.UTF_8)
    fun reply(request: String, result: RemoteHarnessJSON): Boolean = owner.receive(context,
        frame("rpc.response", obj("requestId" to str(request), "result" to result)))
    fun gateway(request: String, value: RemoteHarnessJSON? = obj()) = reply(request, obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to value))
    fun acknowledgeStream(frame: RemoteHarnessFrame, closed: Boolean = true): Boolean {
        val stream = frame.payload.values.rhRequired("params").objectValue().rhString("streamId")
        val closing = frame.payload.values.rhString("method") == RemoteHarnessCodec.CLOSE
        if (closing) hostSlots.remove(stream)
        return reply(frame.id, obj((if (closing) "closed" else "opened") to RemoteHarnessJSON.BooleanValue(if (closing) closed else true), "streamId" to str(stream)))
    }
    fun remoteError(request: String, code: String = "RESPONSE_TOO_LARGE") = owner.receive(context,
        frame("rpc.error", obj("requestId" to str(request), "code" to str(code), "message" to str("private remote diagnostic"), "retryable" to RemoteHarnessJSON.BooleanValue(true))))
    fun event(stream: String, value: RemoteHarnessJSON?, declaredSession: String? = null): Boolean = owner.receive(context,
        frame("event", obj("event" to str(RemoteHarnessCodec.STREAM_FRAME), "data" to obj("streamId" to str(stream),
            "hasValue" to RemoteHarnessJSON.BooleanValue(true), "value" to value), "sessionId" to declaredSession?.let(::str))))
    fun closed(stream: String, reason: String) = owner.receive(context, frame("event", obj("event" to str(RemoteHarnessCodec.STREAM_CLOSED),
        "data" to obj("streamId" to str(stream), "reason" to str(reason)))))
    fun reconnect() { context = context.copy(generation = context.generation + 1, connectionID = "connection-${context.generation + 1}"); owner.beginConnection(context) }
}

/** Host JVM fake-Host verification. Prints IDs/counts only, never frames, transcripts or diagnostics. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val file = File(args[0]); check(file.length() <= RemoteHarnessBounds.FRAME_BYTES)
    val root = RemoteHarnessJSON.parse(file.readText(Charsets.UTF_8)).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L)
    var fixtureCount = 0; var behaviorCount = 0
    val seen = mutableSetOf<String>()
    fun case(id: String, fixture: Boolean = false, block: () -> Unit) {
        check(seen.add(id))
        try { block() } catch (_: Throwable) { System.err.println("REMOTE_HARNESS_CASE_FAIL $id"); throw IllegalStateException("Remote Harness verification failed: $id") }
        if (fixture) { fixtureCount++; println("REMOTE_HARNESS_FIXTURE_PASS $id") }
        else { behaviorCount++; println("REMOTE_HARNESS_BEHAVIOR_PASS $id") }
    }
    for (value in (root.rhRequired("requests") as RemoteHarnessJSON.ArrayValue).values) {
        val c = value.objectValue(); val id = c.rhString("id")
        case(id, true) {
            fun request() = RemoteHarnessCodec.request(c.rhString("method"), c.rhRequired("params"), c.rhString("frameID"), c.rhRequired("timestamp").integerValue(true))
            if (c.containsKey("error")) rhRejected { request() }
            else {
                val generated = request()
                check(rhCanonical(RemoteHarnessJSON.parse(generated.rawJSON)) == rhCanonical(c.rhRequired("expectedFrame")))
                // Check real operation builders, independently of the generic packet encoder.
                val op = when (id) {
                    "session-list" -> RemoteHarnessOperations.sessionList()
                    "session-create" -> RemoteHarnessOperations.sessionCreate("workspace-fixture")
                    "workspace-follow" -> RemoteHarnessOperations.workspaceFollow()
                    "session-follow" -> RemoteHarnessOperations.sessionFollow("session-fixture")
                    "history-page" -> RemoteHarnessOperations.sessionPage("session-fixture", 42, 21)
                    "prompt" -> RemoteHarnessOperations.sessionPrompt("session-fixture", "command-fixture", "Explain 世界", "Asia/Ulaanbaatar")
                    "stop" -> RemoteHarnessOperations.sessionCancel("session-fixture")
                    "control-follow" -> RemoteHarnessOperations.sessionControl()
                    "approval-events" -> RemoteHarnessOperations.approvalEvents()
                    "approval-encoding-only" -> RemoteHarnessOperations.approvalEncodingOnly("event-client-fixture", "approval-fixture", true)
                    "model-catalog" -> RemoteHarnessOperations.modelCatalog()
                    "model-selection" -> RemoteHarnessOperations.selectModel("session-fixture", "deepseek", "deepseek-flash", "high")
                    else -> null
                }
                if (op != null) check(rhCanonical(op.params(if (op.streaming) "stream-fixture" else null)) == rhCanonical(c.rhRequired("params")))
            }
        }
    }
    for (value in (root.rhRequired("frames") as RemoteHarnessJSON.ArrayValue).values) {
        val c = value.objectValue()
        case(c.rhString("id"), true) {
            val raw = c.rhString("rawJSON")
            if (c.containsKey("error")) rhRejected { RemoteHarnessCodec.decode(raw) }
            else {
                val frame = RemoteHarnessCodec.decode(raw.toByteArray(Charsets.UTF_8)); val expected = c.rhRequired("expected").objectValue()
                check(frame.rawJSON == raw && frame.type == expected.rhString("type"))
                expected["requestID"]?.let { check(frame.requestID == it.stringValue()) }
                expected["eventName"]?.let { check(frame.eventName == it.stringValue()) }
                expected["streamID"]?.let { check(frame.streamID == it.stringValue()) }
                check(rhCanonical(RemoteHarnessJSON.parse(frame.rawJSON)) == rhCanonical(RemoteHarnessJSON.parse(raw)))
            }
        }
    }
    case("behavior-discovery-binding-validation") {
        val binding = RemoteHarnessTransportBinding.discovery("enrollment-draft-a", "HTTPS://Relay.Example:443/", "Host-A", "a".repeat(64))
        check(binding.scopeReference == "enrollment-draft-a" && binding.origin == "https://relay.example" &&
            binding.hostID == "Host-A" && binding.hostFingerprint == "a".repeat(64) && binding.workspaceID == null)
        check(binding.toString() == "RemoteHarnessTransportBinding(redacted)")
        for (origin in listOf("http://relay.example", "https://relay.example/path", "https://user@relay.example", "https://relay.example?x=1")) {
            connectionRejected("invalid-origin") { RemoteHarnessTransportBinding.discovery("draft", origin, "host-a", "a".repeat(64)) }
        }
        connectionRejected("noncanonical-origin") { binding.copy(origin = "HTTPS://Relay.Example/") }
        for (invalid in listOf("", "a b", "a".repeat(129))) {
            connectionRejected("invalid-identifier") { binding.copy(scopeReference = invalid) }
            connectionRejected("invalid-identifier") { binding.copy(hostID = invalid) }
            connectionRejected("invalid-identifier") { binding.copy(workspaceID = invalid) }
        }
        for (pin in listOf("", "a".repeat(63), "a".repeat(65), "A".repeat(64), "g".repeat(64))) {
            connectionRejected("invalid-digest") { binding.copy(hostFingerprint = pin) }
        }
        connectionRejected("invalid-destination") { ConversationBinding.create("remote", ConnectionKind.REMOTE_HARNESS,
            binding.origin, binding.hostID, binding.hostFingerprint) }
        connectionRejected("invalid-destination") { ConversationBinding("remote", ConnectionKind.REMOTE_HARNESS,
            binding.origin, binding.hostID, binding.hostFingerprint, null) }
        connectionRejected("invalid-destination") { ConnectionProfile.create("remote", ConnectionKind.REMOTE_HARNESS,
            "Remote", binding.origin, hostID = binding.hostID, hostFingerprint = binding.hostFingerprint) }
        connectionRejected("invalid-destination") { ConnectionProfile("remote", ConnectionKind.REMOTE_HARNESS,
            "Remote", binding.origin, null, binding.hostID, binding.hostFingerprint, null) }
        val context = RemoteHarnessAuthenticatedContext(binding, "device-a", "connection-a", 1)
        check(context.sessionID == null && context.toString() == "RemoteHarnessAuthenticatedContext(redacted)")
        rhRejected("invalid-binding") { context.copy(sessionID = "session-a") }
        rhRejected("invalid-id") { context.copy(callerDeviceID = "") }
        rhRejected("invalid-id") { context.copy(connectionID = "") }
        rhRejected("invalid-generation") { context.copy(generation = 0) }
    }
    case("behavior-transport-conversation-conversion") {
        val original = ConversationBinding.create("profile-original", ConnectionKind.REMOTE_HARNESS,
            "https://relay.example:8443", "Host-Exact_A", "b".repeat(64), "Workspace-A")
        val binding = RemoteHarnessTransportBinding.from(original)
        check(binding.scopeReference == original.profileID && binding.origin == original.origin && binding.hostID == original.hostID &&
            binding.hostFingerprint == original.hostFingerprint && binding.workspaceID == original.workspaceID)
        val context = RemoteHarnessAuthenticatedContext(binding, "device-original", "connection-original", 1, "session-original")
        check(context == RemoteHarnessAuthenticatedContext(original, "device-original", "connection-original", 1, "session-original"))
        for (other in listOf(ConversationBinding.from(ConnectionProfile.localDefault()),
            ConversationBinding.create("provider", ConnectionKind.DEEPSEEK, "https://api.deepseek.com"))) {
            connectionRejected("invalid-binding") { RemoteHarnessTransportBinding.from(other) }
            connectionRejected("invalid-binding") { RemoteHarnessAuthenticatedContext(other, "device-a", "connection-a", 1) }
        }
        val f = HarnessFake(context); f.ready(); val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.call(RemoteHarnessOperations.sessionCancel("session-original"), "cancel-original", outcomes::add)
        check(f.journal.commands.single().context == context && f.journal.commands.single().context.binding == binding)
        check(f.gateway(id, obj("accepted" to RemoteHarnessJSON.BooleanValue(true))))
        check(outcomes.single().kind == RemoteHarnessOutcomeKind.STOP_RECEIPT)
        rhRejected("workspace-binding-mismatch") { f.owner.call(RemoteHarnessOperations.sessionCreate("workspace-other"), "create-other") {} }
    }
    case("behavior-discovery-workspace-follow") {
        val f = HarnessFake(RemoteHarnessAuthenticatedContext(RemoteHarnessTransportBinding.discovery("draft-first-run",
            "https://relay.example", "host-a", "a".repeat(64)), "device-a", "connection-a", 1))
        rhRejected("capabilities-required") { f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}) }
        f.ready(); check(f.sent.single().payload.values.rhString("method") == RemoteHarnessCodec.DESCRIBE)
        val order = arrayListOf<String>(); val values = arrayListOf<RemoteHarnessJSON?>()
        val snapshot = obj("workspaces" to RemoteHarnessJSON.ArrayValue(listOf(obj("id" to str("workspace-real")))))
        f.onSend = { frame ->
            if (frame.payload.values.rhString("method") == RemoteHarnessCodec.OPEN) {
                val stream = frame.payload.values.rhRequired("params").objectValue().rhString("streamId")
                check(f.event(stream, snapshot))
            }
            check(f.acknowledgeStream(frame))
        }
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), { values.add(it.value); order.add("value") }, {
            check(it.kind == RemoteHarnessOutcomeKind.RESULT); order.add("ack")
        })
        check(order == listOf("value", "ack") && rhCanonical(values.single()!!) == rhCanonical(snapshot) &&
            f.owner.pendingCount() == 0 && f.owner.streamCount() == 1)
        check(f.context.binding.workspaceID == null && f.context.sessionID == null && f.journal.commands.isEmpty())
        f.owner.closeStream(stream)
        check(f.owner.hostSlotCount() == 0 && f.owner.streamCount() == 0 && f.journal.commands.isEmpty())
    }
    case("behavior-discovery-rejects-scoped-operations-before-journal") {
        val f = HarnessFake(RemoteHarnessAuthenticatedContext(RemoteHarnessTransportBinding.discovery("draft-first-run",
            "https://relay.example", "host-a", "a".repeat(64)), "device-a", "connection-a", 1)); f.ready()
        val initial = f.sent.size
        val operations = listOf(RemoteHarnessOperations.sessionList(), RemoteHarnessOperations.modelCatalog(),
            RemoteHarnessOperations.sessionCreate("workspace-real"), RemoteHarnessOperations.sessionFollow("session-a"),
            RemoteHarnessOperations.sessionPage("session-a", 42, 21), RemoteHarnessOperations.sessionPrompt("session-a", "prompt-a", "hello"),
            RemoteHarnessOperations.sessionCancel("session-a"), RemoteHarnessOperations.selectModel("session-a", "deepseek", "deepseek-flash"),
            RemoteHarnessOperations.sessionControl(), RemoteHarnessOperations.approvalEvents(),
            RemoteHarnessOperations.approvalEncodingOnly("client-a", "event-a", true),
            RemoteHarnessOperation("workspace/follow", obj(), true, true, null, null))
        for (operation in operations) {
            rhRejected("workspace-binding-required") {
                if (operation.streaming) f.owner.open(operation, {})
                else f.owner.call(operation, if (operation.mutating) operation.logicalCommandID ?: "command-a" else null) {}
            }
            check(f.sent.size == initial && f.journal.commands.isEmpty() && f.owner.pendingCount() == 0 && f.owner.hostSlotCount() == 0)
        }
    }
    case("behavior-discovery-context-isolation") {
        val f = HarnessFake(RemoteHarnessAuthenticatedContext(RemoteHarnessTransportBinding.discovery("draft-first-run",
            "https://relay.example", "host-a", "a".repeat(64)), "device-a", "connection-a", 1)); f.ready()
        var values = 0
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), { values++ })
        val wrong = listOf(f.context.copy(callerDeviceID = "other"), f.context.copy(connectionID = "other"), f.context.copy(generation = 2),
            f.context.copy(binding = f.context.binding.copy(scopeReference = "draft-other")),
            f.context.copy(binding = f.context.binding.copy(origin = "https://other.example")),
            f.context.copy(binding = f.context.binding.copy(hostID = "other")),
            f.context.copy(binding = f.context.binding.copy(hostFingerprint = "b".repeat(64))),
            f.context.copy(binding = f.context.binding.copy(workspaceID = "workspace-real")))
        wrong.forEach { check(!f.owner.receive(it, byteArrayOf(0xff.toByte()))) }
        check(f.owner.pendingCount() == 1 && f.owner.streamCount() == 1 && values == 0)
        check(!f.event(stream, obj(), "session-other"))
        check(f.event(stream, obj()) && values == 1)
        val old = f.context; val sends = f.sent.size
        f.reconnect()
        check(f.sent.size == sends && f.invalidated.single() == old && !f.owner.isReady())
        check(!f.owner.receive(old, byteArrayOf(0xff.toByte())) && f.owner.pendingCount() == 0 && f.owner.streamCount() == 0)
        f.owner.disconnected(old); f.ready(); check(f.owner.isReady())
        rhRejected("stale-generation") { f.owner.beginConnection(old) }
    }
    case("behavior-capability-negotiation") {
        val f = HarnessFake()
        rhRejected("capabilities-required") { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        for (names in listOf(emptyList(), listOf("harness.remote.v1"), listOf("harness.remote.v1", "harness.remote.v3"), listOf("harness.remote.v3", "harness.remote.v3"))) {
            rhRejected { RemoteHarnessCodec.requireV3(obj("capabilities" to RemoteHarnessJSON.ArrayValue(names.map(::str)))) }
        }
        f.ready()
    }
    case("behavior-stream-before-open-ack") {
        val f = HarnessFake(); f.ready(); val order = arrayListOf<String>()
        f.onSend = { frame ->
            val stream = frame.payload.values.rhRequired("params").objectValue().rhString("streamId")
            check(f.event(stream, obj("type" to str("snapshot"), "records" to RemoteHarnessJSON.ArrayValue(emptyList()))))
            f.acknowledgeStream(frame)
        }
        val stream = f.owner.open(RemoteHarnessOperations.sessionFollow("session-a"), { notice ->
            check(notice.value!!.objectValue().rhString("type") == "snapshot"); order.add("value")
        }, { check(it.kind == RemoteHarnessOutcomeKind.RESULT); order.add("ack") })
        check(order == listOf("value", "ack") && f.owner.streamCount() == 1)
        f.onSend = null; f.owner.closeStream(stream)
        check(f.owner.streamCount() == 0 && !f.event(stream, obj()))
    }
    case("behavior-correlation-once-and-opaque-results") {
        val f = HarnessFake(); f.ready(); val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.call(RemoteHarnessOperations.sessionList(), completion = outcomes::add)
        val opaque = RemoteHarnessJSON.parse("{\"records\":[{\"unknown\":1.2300e+400,\"reasoning_content\":\"private\"}],\"future\":true}")
        check(f.gateway(id, opaque)); check(!f.gateway(id, opaque)); check(!f.gateway("unknown", opaque))
        check(outcomes.size == 1 && RemoteHarnessJSON.write(outcomes.single().value!!).contains("1.2300e+400"))
        val prompt = f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "logical-a", "hello"), completion = outcomes::add)
        check(prompt != "logical-a" && f.journal.commands.single().logicalCommandID == "logical-a")
        f.gateway(prompt, null)
        check(outcomes.last().kind == RemoteHarnessOutcomeKind.MUTATION_RECEIPT && outcomes.last().value == null)
        rhRejected { RemoteHarnessCodec.gatewayResult(obj("ok" to str("true"))) }
    }
    case("behavior-journal-before-send-and-failure") {
        val f = HarnessFake(); f.ready()
        val initial = f.sent.size; f.journal.reject = true
        rhRejected("journal-rejected") { f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "rejected", "x")) {} }
        check(f.sent.size == initial && f.owner.pendingCount() == 0)
        f.journal.reject = false; f.journal.throwing = true
        rhRejected("journal-rejected") { f.owner.call(RemoteHarnessOperations.sessionCancel("session-a"), "throwing") {} }
        check(f.sent.size == initial)
        f.journal.throwing = false
        f.onSend = { frame -> check(f.journal.commands.last().wireRequestID == frame.id) }
        f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "saved", "x")) {}
        check(f.sent.size == initial + 1)
    }
    case("behavior-disconnect-unknown-no-replay-and-stale-generation") {
        val f = HarnessFake(); f.ready(); val results = arrayListOf<RemoteHarnessOutcome>()
        val mutation = f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "never-replay", "x"), completion = results::add)
        f.owner.call(RemoteHarnessOperations.sessionList(), completion = results::add)
        val old = f.context; f.owner.disconnected(old)
        check(results.map { it.kind } == listOf(RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN, RemoteHarnessOutcomeKind.LOCAL_FAILURE))
        val sends = f.sent.size; f.reconnect(); check(f.sent.size == sends && !f.owner.isReady())
        check(!f.owner.receive(old, byteArrayOf(0xff.toByte())))
        check(!f.owner.receive(old, f.frame("rpc.response", obj("requestId" to str(mutation), "result" to obj("ok" to RemoteHarnessJSON.BooleanValue(true))))))
        f.ready()
        rhRejected("journal-rejected") { f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "never-replay", "x")) {} }
        rhRejected("stale-generation") { f.owner.beginConnection(old) }
    }
    case("behavior-cross-binding-ignored-before-state") {
        val f = HarnessFake(); f.ready(); var count = 0
        val id = f.owner.call(RemoteHarnessOperations.sessionList()) { count++ }
        val bytes = f.frame("rpc.response", obj("requestId" to str(id), "result" to obj("ok" to RemoteHarnessJSON.BooleanValue(true))))
        val wrong = listOf(f.context.copy(callerDeviceID = "other"), f.context.copy(connectionID = "other"), f.context.copy(generation = 2),
            f.context.copy(sessionID = "other"), f.context.copy(binding = f.context.binding.copy(hostID = "other")),
            f.context.copy(binding = f.context.binding.copy(workspaceID = "other")), f.context.copy(binding = f.context.binding.copy(hostFingerprint = "b".repeat(64))))
        wrong.forEach { check(!f.owner.receive(it, bytes)) }; check(count == 0 && f.owner.pendingCount() == 1)
        check(f.owner.receive(f.context, bytes)); check(count == 1)
        rhRejected("session-binding-mismatch") { f.owner.call(RemoteHarnessOperations.sessionCancel("session-b"), "bad-session") {} }
        rhRejected("workspace-binding-mismatch") { f.owner.call(RemoteHarnessOperations.sessionCreate("workspace-b"), "bad-workspace") {} }
        var values = 0
        val stream = f.owner.open(RemoteHarnessOperations.sessionFollow("session-a"), { values++ })
        check(!f.event(stream, obj(), "session-b"))
        check(!f.event(stream, obj("sessionId" to str("session-b"))))
        check(f.event(stream, obj("sessionId" to str("session-a")), "session-a")); check(values == 1)
    }
    case("behavior-stop-receipt-distinct-from-host-state") {
        val f = HarnessFake(); f.ready(); var result: RemoteHarnessOutcome? = null
        val id = f.owner.call(RemoteHarnessOperations.sessionCancel("session-a"), "cancel-a") { result = it }
        f.gateway(id, obj("accepted" to RemoteHarnessJSON.BooleanValue(true)))
        check(result?.kind == RemoteHarnessOutcomeKind.STOP_RECEIPT)
        // Stop receipt does not cancel the authoritative follow or synthesize a stopped event.
        val notices = arrayListOf<RemoteHarnessStreamNotice>()
        val stream = f.owner.open(RemoteHarnessOperations.sessionFollow("session-a"), notices::add)
        f.event(stream, obj("type" to str("event"), "event" to obj("type" to str("running"), "data" to obj("running" to RemoteHarnessJSON.BooleanValue(true)))))
        f.closed(stream, "peer-disconnected")
        check(notices.last().reason == "peer-disconnected" && result?.kind == RemoteHarnessOutcomeKind.STOP_RECEIPT)
    }
    case("behavior-deadline-unknown-late-response-and-no-transfer") {
        val f = HarnessFake(); f.ready(); val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "timed-out", "x"), completion = outcomes::add)
        f.owner.call(RemoteHarnessOperations.sessionList(), completion = outcomes::add)
        f.clock.now += RemoteHarnessBounds.DEADLINE_MS; f.owner.expire()
        check(outcomes.map { it.kind } == listOf(RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN, RemoteHarnessOutcomeKind.LOCAL_FAILURE))
        check(!f.gateway(id)); check(f.owner.pendingCount() == 0)
        val large = f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "large-response", "x"), completion = outcomes::add)
        val count = f.sent.size; f.remoteError(large)
        check(outcomes.last().kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && f.sent.size == count)
        check(f.sent.none { it.payload.values.rhString("method").contains("transfer") })
    }
    case("behavior-approval-fail-closed-preserves-request") {
        val f = HarnessFake(); f.ready(); var raw: RemoteHarnessJSON? = null
        val stream = f.owner.open(RemoteHarnessOperations.approvalEvents(), { raw = it.value })
        val request = obj("type" to str("waterfall"), "event" to str("approval/request"), "eventId" to str("approval-a"),
            "agentId" to str("session-a"), "request" to obj("toolName" to str("shell"), "futureAction" to obj("opaque" to num(1))))
        f.event(stream, request)
        check(rhCanonical(raw!!) == rhCanonical(request))
        val count = f.sent.size
        for (allowed in listOf(true, false)) rhRejected("approval-binding-unavailable") {
            f.owner.call(RemoteHarnessOperations.approvalEncodingOnly("client-a", "approval-a", allowed), "decision-a") {}
        }
        check(f.sent.size == count && f.journal.commands.isEmpty())
    }
    case("behavior-pending-and-stream-bounds") {
        val f = HarnessFake(); f.ready()
        repeat(RemoteHarnessBounds.PENDING_RPC) { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        rhRejected("pending-limit") { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        check(f.owner.pendingCount() == RemoteHarnessBounds.PENDING_RPC)
        f.owner.disconnected(f.context); f.reconnect(); f.ready()
        f.onSend = { f.acknowledgeStream(it) }
        repeat(RemoteHarnessBounds.STREAMS) { f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}) }
        rhRejected("stream-limit") { f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}) }
        check(f.owner.streamCount() == RemoteHarnessBounds.STREAMS && f.owner.pendingCount() == 0)
    }
    case("behavior-failed-open-cleans-host-slot") {
        val f = HarnessFake(); f.ready(); val notices = arrayListOf<RemoteHarnessStreamNotice>()
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), notices::add)
        val open = f.sent.last(); f.remoteError(open.id, "UNAVAILABLE")
        check(f.owner.streamCount() == 0 && notices.single().reason == "open-failed")
        check(f.sent.last().payload.values.rhString("method") == RemoteHarnessCodec.CLOSE)
        check(f.sent.last().payload.values.rhRequired("params").objectValue().rhString("streamId") == stream)
        val second = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        f.clock.now += RemoteHarnessBounds.DEADLINE_MS; f.owner.expire()
        check(f.owner.streamCount() == 0 && !f.event(second, obj()))
    }
    case("behavior-contextual-open-ack-validation") {
        val invalid = listOf<RemoteHarnessJSON>(obj(), RemoteHarnessJSON.NullValue, RemoteHarnessJSON.BooleanValue(true),
            obj("opened" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str("other-stream")),
            obj("opened" to RemoteHarnessJSON.BooleanValue(false), "streamId" to str("STREAM")),
            obj("opened" to str("true"), "streamId" to str("STREAM")),
            obj("opened" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str("STREAM"), "future" to num(1)))
        for (ack in invalid) {
            val f = HarnessFake(); f.ready(); val outcomes = arrayListOf<RemoteHarnessOutcome>()
            val notices = arrayListOf<RemoteHarnessStreamNotice>()
            f.onSend = { frame -> if (frame.payload.values.rhString("method") == RemoteHarnessCodec.CLOSE) f.acknowledgeStream(frame) }
            val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), notices::add, outcomes::add)
            val opening = f.sent.last()
            val contextual = if (ack is RemoteHarnessJSON.ObjectValue) RemoteHarnessJSON.ObjectValue(ack.values.mapValues {
                if (it.value is RemoteHarnessJSON.StringValue && (it.value as RemoteHarnessJSON.StringValue).value == "STREAM") str(stream) else it.value
            }) else ack
            f.reply(opening.id, contextual)
            check(outcomes.single().kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE)
            check(notices.single().reason == "open-failed" && f.owner.streamCount() == 0)
            check(f.owner.hostSlotCount() == 0 && f.hostSlots.isEmpty() && f.owner.isReady())
        }
    }
    case("behavior-contextual-close-ack-validation") {
        val invalid = listOf<RemoteHarnessJSON>(obj(), RemoteHarnessJSON.NullValue,
            obj("closed" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str("other-stream")),
            obj("closed" to str("true"), "streamId" to str("STREAM")),
            obj("closed" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str("STREAM"), "future" to num(1)))
        for (ack in invalid) {
            val f = HarnessFake(); f.ready()
            f.onSend = { if (it.payload.values.rhString("method") == RemoteHarnessCodec.OPEN) f.acknowledgeStream(it) }
            val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
            f.owner.closeStream(stream); val closing = f.sent.last()
            val contextual = if (ack is RemoteHarnessJSON.ObjectValue) RemoteHarnessJSON.ObjectValue(ack.values.mapValues {
                if (it.value is RemoteHarnessJSON.StringValue && (it.value as RemoteHarnessJSON.StringValue).value == "STREAM") str(stream) else it.value
            }) else ack
            f.reply(closing.id, contextual)
            check(!f.owner.isReady() && f.invalidated == listOf(f.context))
            check(f.hostSlots.isEmpty() && f.owner.hostSlotCount() == 0 && f.owner.pendingCount() == 0)
        }
        // closed=false is a valid Host acknowledgement that no stream remained registered.
        val f = HarnessFake(); f.ready(); f.onSend = { f.acknowledgeStream(it, closed = false) }
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        f.owner.closeStream(stream)
        check(f.owner.isReady() && f.invalidated.isEmpty() && f.owner.hostSlotCount() == 0)
    }
    case("behavior-closing-streams-reserve-host-slots") {
        val f = HarnessFake(); f.ready()
        f.onSend = { if (it.payload.values.rhString("method") == RemoteHarnessCodec.OPEN) f.acknowledgeStream(it) }
        repeat(RemoteHarnessBounds.STREAMS) {
            val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
            f.owner.closeStream(stream)
        }
        check(f.owner.streamCount() == 0 && f.owner.hostSlotCount() == RemoteHarnessBounds.STREAMS && f.hostSlots.size == RemoteHarnessBounds.STREAMS)
        rhRejected("stream-limit") { f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}) }
        val close = f.sent.first { it.payload.values.rhString("method") == RemoteHarnessCodec.CLOSE }
        f.acknowledgeStream(close)
        check(f.owner.hostSlotCount() == RemoteHarnessBounds.STREAMS - 1)
        f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        check(f.owner.hostSlotCount() == RemoteHarnessBounds.STREAMS)
    }
    case("behavior-cleanup-at-capacity-invalidates-connection") {
        val f = HarnessFake(); f.ready()
        f.onSend = { if (it.payload.values.rhString("method") == RemoteHarnessCodec.OPEN) f.acknowledgeStream(it) }
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "cleanup-disconnect", "x"), completion = outcomes::add)
        repeat(RemoteHarnessBounds.PENDING_RPC - 1) { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        val sent = f.sent.size; f.owner.closeStream(stream)
        check(f.sent.size == sent && f.invalidated == listOf(f.context) && !f.owner.isReady())
        check(outcomes.single().kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN)
        check(f.hostSlots.isEmpty() && f.owner.hostSlotCount() == 0 && f.owner.pendingCount() == 0)
        rhRejected("disconnected") { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        val g = HarnessFake(); g.ready()
        val openingStream = g.owner.open(RemoteHarnessOperations.workspaceFollow(), { notice ->
            if (notice.kind == RemoteHarnessStreamNoticeKind.CLOSED) repeat(RemoteHarnessBounds.PENDING_RPC) { g.owner.call(RemoteHarnessOperations.sessionList()) {} }
        })
        val opening = g.sent.last(); g.remoteError(opening.id, "UNAVAILABLE")
        check(g.invalidated == listOf(g.context) && g.hostSlots.isEmpty() && g.owner.hostSlotCount() == 0)
        check(!g.event(openingStream, obj()))
    }
    case("behavior-cleanup-error-send-failure-and-timeout-invalidate") {
        for (failure in listOf("send", "error", "timeout")) {
            val f = HarnessFake(); f.ready()
            f.onSend = { frame ->
                val method = frame.payload.values.rhString("method")
                if (method == RemoteHarnessCodec.OPEN) f.acknowledgeStream(frame)
                else if (failure == "send") error("private close failure")
                else if (failure == "error") f.remoteError(frame.id, "UNAVAILABLE")
            }
            val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
            f.owner.closeStream(stream)
            if (failure == "timeout") { f.clock.now += RemoteHarnessBounds.DEADLINE_MS; f.owner.expire() }
            check(f.invalidated == listOf(f.context) && !f.owner.isReady())
            check(f.hostSlots.isEmpty() && f.owner.hostSlotCount() == 0 && f.owner.pendingCount() == 0)
        }
    }
    case("behavior-failed-channel-invalidation-blocks-owner") {
        val f = HarnessFake(); f.ready()
        f.onSend = { if (it.payload.values.rhString("method") == RemoteHarnessCodec.OPEN) f.acknowledgeStream(it) }
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        f.owner.closeStream(stream); val closing = f.sent.last(); f.invalidateThrows = true
        rhRejected("transport-invalidation-failed") { f.reply(closing.id, obj()) }
        check(!f.owner.isReady() && f.owner.hasUnconfirmedTransportTeardown())
        check(f.hostSlots.contains(stream)) // Adapter failure is explicit; never claim remote cleanup.
        rhRejected("transport-teardown-unconfirmed") { f.reconnect() }
        rhRejected("disconnected") { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
    }
    case("behavior-failed-retirement-cannot-activate-replacement") {
        val f = HarnessFake(); f.ready()
        val stream = f.owner.open(RemoteHarnessOperations.workspaceFollow(), {})
        val old = f.context; val sent = f.sent.size
        f.onInvalidate = {
            rhRejected("disconnected") { f.owner.describe {} }
            rhRejected("connection-retiring") { f.owner.beginConnection(old.copy(generation = 3, connectionID = "reentrant")) }
        }
        f.invalidateThrows = true
        rhRejected("transport-invalidation-failed") { f.reconnect() }
        check(f.invalidated == listOf(old) && f.hostSlots.contains(stream))
        check(f.owner.hasUnconfirmedTransportTeardown() && !f.owner.isReady() && f.sent.size == sent)
        rhRejected("transport-teardown-unconfirmed") { f.reconnect() }
        rhRejected("disconnected") { f.owner.describe {} }
        check(!f.owner.receive(old, byteArrayOf(0xff.toByte())))
    }
    case("behavior-open-completes-once-through-cleanup-teardown-failure") {
        for (failure in listOf("rpc-error", "malformed-response", "open-timeout", "open-send")) {
            val f = HarnessFake(); f.ready(); val outcomes = arrayListOf<RemoteHarnessOutcome>()
            f.invalidateThrows = true
            f.onSend = { frame ->
                val method = frame.payload.values.rhString("method")
                if (method == RemoteHarnessCodec.CLOSE || failure == "open-send") error("private port send failure")
            }
            val opening: RemoteHarnessFrame
            if (failure == "open-send") {
                rhRejected("transport-invalidation-failed") { f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}, outcomes::add) }
                opening = f.sent.first { it.payload.values.rhString("method") == RemoteHarnessCodec.OPEN }
            } else {
                f.owner.open(RemoteHarnessOperations.workspaceFollow(), {}, outcomes::add)
                opening = f.sent.last()
                rhRejected("transport-invalidation-failed") {
                    when (failure) {
                        "rpc-error" -> f.remoteError(opening.id, "UNAVAILABLE")
                        "malformed-response" -> f.reply(opening.id, obj())
                        else -> { f.clock.now += RemoteHarnessBounds.DEADLINE_MS; f.owner.expire() }
                    }
                }
            }
            check(outcomes.size == 1 && outcomes.single().wireRequestID == opening.id)
            check(outcomes.single().kind == if (failure == "rpc-error") RemoteHarnessOutcomeKind.REMOTE_FAILURE else RemoteHarnessOutcomeKind.LOCAL_FAILURE)
            check(outcomes.single().errorCode == when (failure) {
                "rpc-error" -> "remote-error"; "malformed-response" -> "invalid-response"; "open-timeout" -> "deadline-exceeded"; else -> "send-failed"
            })
            check(f.owner.hasUnconfirmedTransportTeardown() && !f.owner.isReady() && f.owner.pendingCount() == 0)
            check(f.invalidated.size == 1 && f.hostSlots.isNotEmpty())
            check(!f.gateway(opening.id)); f.owner.expire(); f.owner.disconnected(f.context)
            check(outcomes.size == 1)
            rhRejected("transport-teardown-unconfirmed") { f.reconnect() }
        }
    }
    case("behavior-send-throws-after-dispatch-is-unknown") {
        val f = HarnessFake(); f.ready(); var result: RemoteHarnessOutcome? = null
        f.onSend = { error("private port error") }
        f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "send-throws", "x")) { result = it }
        check(result?.kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && f.owner.pendingCount() == 0)
    }
    case("behavior-reserved-capacity-before-reentrant-journal") {
        val f = HarnessFake(); f.ready()
        repeat(RemoteHarnessBounds.PENDING_RPC - 1) { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        f.journal.onPrepare = { command ->
            check(f.owner.pendingCount() == RemoteHarnessBounds.PENDING_RPC)
            check(!f.gateway(command.wireRequestID)) // No response can settle an unsent reservation.
            rhRejected("pending-limit") { f.owner.call(RemoteHarnessOperations.sessionList()) {} }
        }
        f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "reentrant-reservation", "x")) {}
        check(f.owner.pendingCount() == RemoteHarnessBounds.PENDING_RPC)
    }
    case("behavior-journal-connection-change-prevents-dispatch") {
        val f = HarnessFake(); f.ready(); val before = f.sent.size
        f.journal.onPrepare = { f.reconnect() }
        rhRejected("connection-changed") { f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "journal-reconnect", "x")) {} }
        check(f.sent.size == before && f.owner.pendingCount() == 0 && !f.owner.isReady())
        f.journal.onPrepare = null; f.ready()
        f.journal.onPrepare = { f.clock.now += RemoteHarnessBounds.DEADLINE_MS }
        val saved = f.sent.size
        rhRejected("deadline-exceeded") { f.owner.call(RemoteHarnessOperations.sessionPrompt("session-a", "journal-timeout", "x")) {} }
        check(f.sent.size == saved && f.owner.pendingCount() == 0)
    }
    case("behavior-bounded-strict-json-and-redaction") {
        rhRejected("frame-limit") { RemoteHarnessJSON.parse(ByteArray(RemoteHarnessBounds.FRAME_BYTES + 1)) }
        rhRejected("json-depth") { RemoteHarnessJSON.parse("[".repeat(32) + "0" + "]".repeat(32)) }
        rhRejected("container-limit") { RemoteHarnessJSON.parse("[" + List(1025) { "0" }.joinToString(",") + "]") }
        rhRejected("container-limit") { RemoteHarnessJSON.parse("{" + List(1025) { "\"k$it\":0" }.joinToString(",") + "}") }
        rhRejected("invalid-utf8") { RemoteHarnessJSON.parse(byteArrayOf(0xc0.toByte(), 0xaf.toByte())) }
        rhRejected("invalid-unicode") { RemoteHarnessJSON.parse("\"\\ud800\"") }
        rhRejected("duplicate-key") { RemoteHarnessJSON.parse("{\"a\":0,\"a\":1}") }
        rhRejected("text-limit") { RemoteHarnessOperations.sessionPrompt("session-a", "too-big", "世".repeat(21846)) }
        val mutable = arrayListOf<RemoteHarnessJSON>(str("secret")); val snapshot = RemoteHarnessJSON.ArrayValue(mutable); mutable.clear()
        check(snapshot.values.size == 1 && !snapshot.toString().contains("secret"))
        rhRejected("invalid-timezone") { RemoteHarnessOperations.sessionPrompt("session-a", "zone", "x", "GMT") }
    }
    println("REMOTE_HARNESS_VERIFY_PASS fixtures=$fixtureCount behaviors=$behaviorCount")
}
