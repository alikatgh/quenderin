package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.io.File

private fun botReject(code: String? = null, block: () -> Unit) {
    val failure = try { block(); null } catch (error: RemoteHarnessException) { error }
    check(failure != null && (code == null || failure.code == code))
    check("SYNTHETIC_PRIVATE" !in failure.toString() && "PRIVATE_SYNTHETIC" !in failure.toString())
}
private fun botCanonical(value: RemoteHarnessJSON): String {
    fun sorted(v: RemoteHarnessJSON): RemoteHarnessJSON = when (v) {
        is RemoteHarnessJSON.ObjectValue -> RemoteHarnessJSON.ObjectValue(v.values.toSortedMap().mapValues { sorted(it.value) })
        is RemoteHarnessJSON.ArrayValue -> RemoteHarnessJSON.ArrayValue(v.values.map(::sorted))
        else -> v
    }
    return RemoteHarnessJSON.write(sorted(value))
}
private fun botEntry(id: String = "bot-a", sessionID: String = "session-a", name: String = "Assistant",
    model: RemoteHarnessJSON = RemoteHarnessJSON.NullValue, permission: RemoteHarnessJSON = RemoteHarnessJSON.NullValue) =
    obj("id" to str(id), "sessionId" to str(sessionID), "name" to str(name), "model" to model, "permission" to permission)
private fun botResult(workspace: String = "workspace-a", bots: List<RemoteHarnessJSON> = listOf(botEntry()), revision: RemoteHarnessJSON = num(7), readOnly: Boolean = true) =
    obj("status" to num(200), "json" to obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to obj(
        "schemaVersion" to num(1), "workspaceId" to str(workspace), "revision" to revision,
        "readOnly" to RemoteHarnessJSON.BooleanValue(readOnly), "bots" to RemoteHarnessJSON.ArrayValue(bots))))

private class BotReadFake(discovery: Boolean = false) {
    var now = 1L
    var context = RemoteHarnessAuthenticatedContext(RemoteHarnessTransportBinding("profile-a", "https://relay.example", "host-a", "a".repeat(64),
        if (discovery) null else "workspace-a"), "device-a", "connection-a", 1, if (discovery) null else "session-a")
    val sent = arrayListOf<RemoteHarnessFrame>()
    val invalidated = arrayListOf<RemoteHarnessAuthenticatedContext>()
    var journalCount = 0
    var sendThrows = false
    var onSend: ((RemoteHarnessFrame) -> Unit)? = null
    val owner = RemoteHarnessCoordinator(object : RemoteHarnessDecryptedPort {
        override fun send(context: RemoteHarnessAuthenticatedContext, frame: ByteArray) {
            check(context == this@BotReadFake.context)
            val decoded = RemoteHarnessCodec.decode(frame); sent.add(decoded)
            if (sendThrows) error("SYNTHETIC_PRIVATE_SEND_ERROR")
            onSend?.invoke(decoded)
        }
        override fun invalidate(context: RemoteHarnessAuthenticatedContext) { invalidated.add(context) }
    }, object : RemoteHarnessClock {
        override fun epochMilliseconds() = now
        override fun monotonicMilliseconds() = now
    }, RemoteHarnessMutationJournal { journalCount++; true })
    init { owner.beginConnection(context) }
    fun describe(capabilities: List<String> = listOf(RemoteHarnessCodec.REQUIRED_CAPABILITY, RemoteHarnessBotRead.CARRIER_CAPABILITY,
        RemoteHarnessBotRead.CAPABILITY)) {
        val id = owner.describe {}
        check(reply(id, obj("capabilities" to RemoteHarnessJSON.ArrayValue(capabilities.map(::str)))))
        check(owner.isReady())
    }
    fun bytes(requestID: String, result: RemoteHarnessJSON): ByteArray = RemoteHarnessJSON.write(obj("v" to num(1),
        "id" to str("host-reply"), "type" to str("rpc.response"), "timestamp" to num(now),
        "payload" to obj("requestId" to str(requestID), "result" to result))).toByteArray(Charsets.UTF_8)
    fun reply(requestID: String, result: RemoteHarnessJSON) = owner.receive(context, bytes(requestID, result))
    fun rawBytes(requestID: String, result: String) = bytes(requestID, RemoteHarnessJSON.NullValue).toString(Charsets.UTF_8)
        .replace("\"result\":null", "\"result\":$result").toByteArray(Charsets.UTF_8)
    fun stream(operation: RemoteHarnessOperation): String {
        val id = owner.open(operation, {})
        check(reply(sent.last().id, obj("opened" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str(id))))
        return id
    }
    fun event(stream: String, value: RemoteHarnessJSON) = owner.receive(context, RemoteHarnessJSON.write(obj(
        "v" to num(1), "id" to str("host-event"), "type" to str("event"), "timestamp" to num(now), "payload" to obj(
            "event" to str(RemoteHarnessCodec.STREAM_FRAME), "data" to obj("streamId" to str(stream),
                "hasValue" to RemoteHarnessJSON.BooleanValue(true), "value" to value)))).toByteArray(Charsets.UTF_8))
    fun reconnect() {
        context = context.copy(generation = context.generation + 1, connectionID = "connection-${context.generation + 1}")
        owner.beginConnection(context)
    }
}

/** JVM-only synthetic protocol checks. Prints case identifiers/counts, never payloads or diagnostics. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val fixture = File(args[0]); check(fixture.length() <= RemoteHarnessBounds.FRAME_BYTES)
    val root = RemoteHarnessJSON.parse(fixture.readBytes()).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L)
    val workspace = root.rhString("workspaceId")
    val valid = root.rhRequired("valid").objectValue()
    val capabilities = (root.rhRequired("capabilities") as RemoteHarnessJSON.ArrayValue).values.map { it.stringValue() }
    var cases = 0; var fixtures = 0
    val seen = hashSetOf<String>()
    fun case(id: String, fixtureCase: Boolean = false, block: () -> Unit) {
        check(seen.add(id))
        try { block() } catch (_: Throwable) { throw IllegalStateException("BOT_READ_CASE_FAIL $id") }
        cases++; if (fixtureCase) fixtures++
        println("BOT_READ_CASE_PASS $id")
    }
    case("shared-valid-request", true) {
        check(botCanonical(RemoteHarnessBotRead.request(workspace)) == botCanonical(valid.rhRequired("request")))
        val frame = RemoteHarnessCodec.request(RemoteHarnessBotRead.METHOD, valid.rhRequired("request"), "request-a", 1)
        check(frame.payload.values.rhString("method") == "plugin.route.call")
    }
    case("shared-valid-response", true) {
        val raw = RemoteHarnessJSON.write(valid.rhRequired("response")).toByteArray(Charsets.UTF_8)
        val parsed = RemoteHarnessBotRead.result(raw, workspace)
        check(parsed.workspaceID == workspace && parsed.revision == 7L && parsed.readOnly && parsed.schemaVersion == 1)
        check(parsed.bots.size == 2 && parsed.bots[1].name == "Туслагч 助手" && parsed.bots[1].model == null && parsed.bots[1].permission == null)
        check(parsed.toString() == "RemoteHarnessBotRoster(redacted)" && parsed.bots[0].toString() == "RemoteHarnessBotSummary(redacted)")
        var immutable = false
        try { (parsed.bots as MutableList<RemoteHarnessBotSummary>).clear() } catch (_: UnsupportedOperationException) { immutable = true }
        check(immutable && parsed.bots.size == 2)
        // The projector's source object is deliberately not an accepted wire result.
        botReject { RemoteHarnessBotRead.result(valid.rhRequired("source"), workspace) }
    }
    for (value in (root.rhRequired("invalidRequests") as RemoteHarnessJSON.ArrayValue).values) {
        val item = value.objectValue()
        case("shared-request-${item.rhString("id")}", true) {
            botReject { RemoteHarnessBotRead.validateRequest(item.rhRequired("params"), workspace) }
        }
    }
    for (value in (root.rhRequired("invalidResponses") as RemoteHarnessJSON.ArrayValue).values) {
        val item = value.objectValue()
        case("shared-response-${item.rhString("id")}", true) {
            botReject { RemoteHarnessBotRead.result(item.rhRequired("result"), workspace) }
            val f = BotReadFake(); f.describe(capabilities)
            val outcomes = arrayListOf<RemoteHarnessOutcome>()
            val id = f.owner.readBotRoster(outcomes::add)
            check(f.reply(id, item.rhRequired("result")))
            val outcome = outcomes.single()
            check(outcome.kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE && outcome.errorCode == "invalid-response" &&
                outcome.botRoster == null && outcome.value == null && outcome.frame == null && f.journalCount == 0)
            check(f.owner.pendingCount() == 0 && f.owner.streamCount() == 0 && f.owner.pendingApprovals().isEmpty())
        }
    }
    case("capability-pair-required") {
        for (caps in listOf(listOf(RemoteHarnessCodec.REQUIRED_CAPABILITY),
            listOf(RemoteHarnessCodec.REQUIRED_CAPABILITY, RemoteHarnessBotRead.CAPABILITY),
            listOf(RemoteHarnessCodec.REQUIRED_CAPABILITY, RemoteHarnessBotRead.CARRIER_CAPABILITY))) {
            val f = BotReadFake()
            botReject("bot-capabilities-required") { f.owner.readBotRoster {} }
            f.describe(caps); check(!f.owner.botReadSupported())
            val sends = f.sent.size
            botReject("bot-capabilities-required") { f.owner.readBotRoster {} }
            check(f.sent.size == sends && f.journalCount == 0)
        }
    }
    case("discovery-cannot-read-roster") {
        val f = BotReadFake(discovery = true); f.describe(capabilities)
        botReject("workspace-binding-required") { f.owner.readBotRoster {} }
        check(f.sent.size == 1 && f.journalCount == 0)
    }
    case("typed-raw-result-no-journal-or-approval") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.readBotRoster(outcomes::add)
        check(f.sent.last().payload.values.rhString("method") == RemoteHarnessBotRead.METHOD)
        check(botCanonical(f.sent.last().payload.values.rhRequired("params")) == botCanonical(valid.rhRequired("request")))
        check(f.reply(id, valid.rhRequired("response")) && !f.reply(id, valid.rhRequired("response")))
        val result = outcomes.single()
        check(result.kind == RemoteHarnessOutcomeKind.RESULT && result.botRoster?.bots?.size == 2 && result.value == null && result.frame == null &&
            result.context == f.context && result.logicalCommandID == null && f.journalCount == 0 && f.owner.pendingApprovals().isEmpty())
        check(!f.owner.approvalSupported())
        // The fixed session endpoint policy and Gateway parser remain unchanged.
        botReject("unsupported-endpoint") { RemoteHarnessOperations.fromWire("api/bot", obj(), false) }
        botReject { RemoteHarnessCodec.gatewayResult(valid.rhRequired("response")) }
        val call = f.owner.call(RemoteHarnessOperations.sessionList(), completion = outcomes::add)
        check(f.reply(call, obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to obj("sessions" to RemoteHarnessJSON.ArrayValue(emptyList())))))
        check(outcomes.last().kind == RemoteHarnessOutcomeKind.RESULT && outcomes.last().botRoster == null && outcomes.last().value != null)
        val wrong = f.owner.readBotRoster(outcomes::add)
        check(f.reply(wrong, obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to valid.rhRequired("response"))))
        check(outcomes.last().kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE && f.journalCount == 0)
    }
    case("reconnect-clears-capability-and-stale-context") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.readBotRoster(outcomes::add); val old = f.context
        f.reconnect()
        check(outcomes.single().kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE && outcomes.single().errorCode == "disconnected")
        check(!f.owner.botReadSupported() && !f.owner.isReady())
        check(!f.owner.receive(old, byteArrayOf(0xff.toByte())))
        check(!f.owner.receive(old, f.bytes(id, valid.rhRequired("response"))))
        botReject("bot-capabilities-required") { f.owner.readBotRoster {} }
        f.describe(listOf(RemoteHarnessCodec.REQUIRED_CAPABILITY)); check(!f.owner.botReadSupported())
        f.describe(capabilities); check(f.owner.botReadSupported())
        f.owner.disconnected(f.context); check(!f.owner.botReadSupported())
        check(f.journalCount == 0 && f.invalidated == listOf(old))
    }
    case("authenticated-context-isolation-before-parse") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.readBotRoster(outcomes::add)
        val wrong = listOf(f.context.copy(callerDeviceID = "device-b"), f.context.copy(connectionID = "connection-b"),
            f.context.copy(generation = 2), f.context.copy(sessionID = "session-b"),
            f.context.copy(binding = f.context.binding.copy(scopeReference = "profile-b")),
            f.context.copy(binding = f.context.binding.copy(origin = "https://other.example")),
            f.context.copy(binding = f.context.binding.copy(hostID = "host-b")),
            f.context.copy(binding = f.context.binding.copy(hostFingerprint = "b".repeat(64))),
            f.context.copy(binding = f.context.binding.copy(workspaceID = "workspace-b")))
        wrong.forEach { check(!f.owner.receive(it, byteArrayOf(0xff.toByte()))) }
        check(outcomes.isEmpty() && f.owner.pendingCount() == 1 && f.journalCount == 0)
        check(f.reply(id, valid.rhRequired("response")) && outcomes.single().botRoster != null)
    }
    case("bot-failures-preserve-live-streams-stop-and-exact-approval") {
        val f = BotReadFake(); f.describe(capabilities + RemoteHarnessClientApprovalGate.CAPABILITY)
        val workspaceStream = f.stream(RemoteHarnessOperations.workspaceFollow())
        val sessionStream = f.stream(RemoteHarnessOperations.sessionFollow("session-a"))
        val eventStream = f.stream(RemoteHarnessOperations.approvalEvents())
        check(f.event(workspaceStream, obj("type" to str("baseline"), "value" to obj("items" to RemoteHarnessJSON.ArrayValue(listOf(
            obj("workspaceId" to str(workspace), "sessionIds" to RemoteHarnessJSON.ArrayValue(listOf(str("session-a"))))))))))
        check(f.event(sessionStream, obj("type" to str("event"), "event" to obj("type" to str("turn/start"), "data" to obj("turn" to num(1))))))
        check(f.event(eventStream, obj("type" to str("ready"), "clientId" to str("client-a"))))
        val action = obj("tool" to str("fixture-tool"), "arguments" to obj("text" to str("synthetic action")))
        check(f.event(eventStream, obj("type" to str("waterfall"), "event" to str("approval/request"), "eventId" to str("approval-a"),
            "agentId" to str("session-a"), "request" to action, "quenderinBinding" to obj("hostDeviceId" to str("host-a"),
                "clientDeviceId" to str("device-a"), "workspaceId" to str(workspace), "sessionId" to str("session-a"), "runId" to str("turn:1"),
                "eventId" to str("approval-a"), "actionDigest" to str(RemoteHarnessClientApprovalGate.actionDigest(action)), "expiresAt" to num(f.now + 120_000)))))
        val approval = f.owner.pendingApprovals().single()
        val stopOutcomes = arrayListOf<RemoteHarnessOutcome>()
        val stop = f.owner.call(RemoteHarnessOperations.sessionCancel("session-a"), "stop-a", stopOutcomes::add)
        for (invalid in listOf(obj("status" to num(404), "json" to obj("message" to str("SYNTHETIC_PRIVATE_ERROR"))), obj("status" to num(200), "json" to obj()))) {
            val failures = arrayListOf<RemoteHarnessOutcome>(); val read = f.owner.readBotRoster(failures::add)
            check(f.reply(read, invalid) && failures.single().kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE)
            check(f.owner.isReady() && f.owner.botReadSupported() && f.owner.approvalSupported() && f.owner.pendingApprovals().single() === approval)
            check(f.owner.streamCount() == 3 && f.owner.hostSlotCount() == 3 && f.owner.pendingCount() == 1 && f.invalidated.isEmpty() && stopOutcomes.isEmpty())
        }
        check(f.reply(stop, obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to obj("accepted" to RemoteHarnessJSON.BooleanValue(true)))))
        check(stopOutcomes.single().kind == RemoteHarnessOutcomeKind.STOP_RECEIPT && f.journalCount == 1 && f.owner.pendingApprovals().single() === approval)
    }
    case("new-describe-clears-and-older-reply-cannot-enable") {
        val f = BotReadFake(); f.describe(capabilities); check(f.owner.botReadSupported())
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val old = f.owner.describe(outcomes::add); check(!f.owner.botReadSupported())
        val current = f.owner.describe(outcomes::add)
        check(f.reply(current, obj("capabilities" to RemoteHarnessJSON.ArrayValue(listOf(str(RemoteHarnessCodec.REQUIRED_CAPABILITY))))))
        check(f.reply(old, obj("capabilities" to RemoteHarnessJSON.ArrayValue(capabilities.map(::str)))))
        check(!f.owner.botReadSupported() && outcomes.last().kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE)
        val invalid = f.owner.describe(outcomes::add)
        check(f.reply(invalid, obj("capabilities" to RemoteHarnessJSON.ArrayValue(listOf(str(RemoteHarnessBotRead.CAPABILITY))))))
        check(!f.owner.botReadSupported() && !f.owner.isReady())
    }
    case("timeout-no-retry-and-capacity") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        repeat(RemoteHarnessBounds.PENDING_RPC) { f.owner.readBotRoster(outcomes::add) }
        botReject("pending-limit") { f.owner.readBotRoster {} }
        check(f.owner.pendingCount() == RemoteHarnessBounds.PENDING_RPC)
        val sends = f.sent.size; val id = f.sent.last().id
        f.now += RemoteHarnessBounds.DEADLINE_MS; f.owner.expire(); f.owner.expire()
        check(outcomes.size == RemoteHarnessBounds.PENDING_RPC && outcomes.all { it.kind == RemoteHarnessOutcomeKind.LOCAL_FAILURE && it.errorCode == "deadline-exceeded" })
        check(f.sent.size == sends && f.journalCount == 0 && f.owner.pendingCount() == 0)
        check(!f.reply(id, valid.rhRequired("response")))
    }
    case("send-failure-and-remote-error-no-retry-or-private-frame") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>(); f.sendThrows = true
        f.owner.readBotRoster(outcomes::add)
        check(outcomes.single().errorCode == "send-failed" && outcomes.single().frame == null && f.owner.pendingCount() == 0)
        f.sendThrows = false
        val id = f.owner.readBotRoster(outcomes::add)
        val frame = RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("host-error"), "type" to str("rpc.error"), "timestamp" to num(f.now),
            "payload" to obj("requestId" to str(id), "code" to str("PRIVATE_SYNTHETIC_CODE"), "message" to str("SYNTHETIC_PRIVATE_ERROR"),
                "retryable" to RemoteHarnessJSON.BooleanValue(true)))).toByteArray(Charsets.UTF_8)
        check(f.owner.receive(f.context, frame))
        check(outcomes.last().kind == RemoteHarnessOutcomeKind.REMOTE_FAILURE && outcomes.last().errorCode == "remote-error" && outcomes.last().frame == null)
        check(f.journalCount == 0 && f.sent.size == 3)
    }
    case("malformed-bytes-and-schema") {
        botReject("invalid-utf8") { RemoteHarnessBotRead.result(byteArrayOf(0xff.toByte()), workspace) }
        botReject { RemoteHarnessBotRead.result("{\"status\":200,\"status\":200}".toByteArray(), workspace) }
        botReject("invalid-unicode") { RemoteHarnessBotRead.result("{\"status\":200,\"json\":\"\\ud800\"}".toByteArray(), workspace) }
        botReject { RemoteHarnessBotRead.result(botResult(revision = RemoteHarnessJSON.NumberValue("7.5")), workspace) }
        botReject { RemoteHarnessBotRead.result(botResult(revision = RemoteHarnessJSON.NumberValue("1e2")), workspace) }
        botReject { RemoteHarnessBotRead.result(botResult(bots = listOf(botEntry(model = RemoteHarnessJSON.BooleanValue(false)))), workspace) }
        botReject { RemoteHarnessBotRead.result(obj("status" to num(200), "json" to obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to obj())), workspace) }
    }
    case("utf8-string-bounds-and-null-policy") {
        val id = "я".repeat(512); val name = "Ж".repeat(128); val permission = "ю".repeat(32)
        val validBot = botEntry(id, id, name, str(name), str(permission))
        check(RemoteHarnessBotRead.result(botResult(bots = listOf(validBot)), workspace).bots.single().id == id)
        val invalid = listOf(botEntry(id + "я"), botEntry(sessionID = id + "я"), botEntry(name = name + "Ж"),
            botEntry(model = str(name + "Ж")), botEntry(permission = str(permission + "ю")), botEntry(name = ""),
            botEntry(model = str("")), botEntry(permission = str("")), botEntry(id = "bot\u0000a"), botEntry(sessionID = "session\u0000a"),
            botEntry(name = "A\u0000"), botEntry(model = str("m\u0000")), botEntry(permission = str("p\u0000")))
        invalid.forEach { bot -> botReject { RemoteHarnessBotRead.result(botResult(bots = listOf(bot)), workspace) } }
        botReject { RemoteHarnessBotRead.request("я".repeat(513)) }
        botReject { RemoteHarnessBotRead.request("workspace\u0000a") }
        botReject("bot-request-limit") { RemoteHarnessBotRead.request("\u0001".repeat(1024)) }
        botReject { RemoteHarnessBotRead.result(botResult(workspace = ""), workspace) }
        botReject { RemoteHarnessBotRead.result(botResult(), "") }
    }
    case("exact-unicode-workspace-and-identity") {
        val composed = "é"; val decomposed = "e\u0301"
        botReject("workspace-binding-mismatch") { RemoteHarnessBotRead.result(botResult(composed), decomposed) }
        botReject("workspace-binding-mismatch") { RemoteHarnessBotRead.validateRequest(RemoteHarnessBotRead.request(composed), decomposed) }
        val bots = listOf(botEntry(composed, composed), botEntry(decomposed, decomposed), botEntry("Bot-A", "Session-A"), botEntry("bot-a", "session-a"))
        val parsed = RemoteHarnessBotRead.result(botResult(composed, bots), composed)
        check(parsed.workspaceID == composed && parsed.bots.map { it.id } == listOf(composed, decomposed, "Bot-A", "bot-a"))
    }
    case("readonly-false-remains-metadata") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        val id = f.owner.readBotRoster(outcomes::add)
        check(f.reply(id, botResult(readOnly = false)))
        check(outcomes.single().kind == RemoteHarnessOutcomeKind.RESULT && outcomes.single().botRoster?.readOnly == false && f.journalCount == 0)
    }
    case("count-encoded-result-and-safe-revision-bounds") {
        val bots = (0 until 100).map { botEntry("bot-$it", "session-$it") }
        check(RemoteHarnessBotRead.result(botResult(bots = bots, revision = num(RemoteHarnessBounds.SAFE_INTEGER)), workspace).bots.size == 100)
        botReject("bot-count-limit") { RemoteHarnessBotRead.result(botResult(bots = bots + botEntry("bot-101", "session-101")), workspace) }
        botReject("bot-result-limit") { RemoteHarnessBotRead.result(ByteArray(RemoteHarnessBotRead.RESULT_BYTES + 1) { 32 }, workspace) }
        val large = (0 until 100).map { botEntry("$it".padEnd(1024, 'a'), "$it".padEnd(1024, 's'), "n".repeat(256), str("m".repeat(256)), str("p".repeat(64))) }
        botReject("bot-result-limit") { RemoteHarnessBotRead.result(botResult(bots = large), workspace) }
    }
    case("parsed-object-source-counts-preserve-utf8-and-escape-spelling") {
        val child = """{ "raw": "é 助手 😀", "escaped": "\u00e9 \ud83d\ude00", "values": [true,false,null,-1.25e+2,{"x":"\\\""}] }"""
        val source = """ \n {"before":"😀", "child":$child, "after":{"a":0}} \t """.replace("\\n", "\n").replace("\\t", "\t")
        val rootObject = RemoteHarnessJSON.parse(source) as RemoteHarnessJSON.ObjectValue
        val childObject = rootObject.values.rhRequired("child") as RemoteHarnessJSON.ObjectValue
        val originalBytes = checkNotNull(rootObject.sourceUTF8Bytes)
        check(originalBytes == source.trim().toByteArray(Charsets.UTF_8).size)
        check(childObject.sourceUTF8Bytes == child.toByteArray(Charsets.UTF_8).size)
        val canonical = RemoteHarnessJSON.write(rootObject)
        check("sourceUTF8Bytes" !in canonical && canonical.toByteArray(Charsets.UTF_8).size < originalBytes)
        check(RemoteHarnessJSON.ObjectValue(rootObject.values).sourceUTF8Bytes == null)
        check(botCanonical(RemoteHarnessJSON.parse(canonical)) == botCanonical(rootObject))
    }
    case("codec-bounds-original-request-params-exactly") {
        val compact = RemoteHarnessJSON.write(valid.rhRequired("request"))
        fun carrier(size: Int): String {
            val params = "{" + " ".repeat(size - compact.toByteArray(Charsets.UTF_8).size) + compact.substring(1)
            return """{"v":1,"id":"request-raw","type":"rpc.request","timestamp":1,"payload":{"method":"plugin.route.call","params":$params}}"""
        }
        botReject("bot-request-limit") { RemoteHarnessCodec.decode(carrier(RemoteHarnessBotRead.REQUEST_BYTES + 1)) }
        val accepted = RemoteHarnessCodec.decode(carrier(RemoteHarnessBotRead.REQUEST_BYTES))
        check(accepted.payload.values.rhString("method") == RemoteHarnessBotRead.METHOD)
        check((accepted.payload.values.rhRequired("params") as RemoteHarnessJSON.ObjectValue).sourceUTF8Bytes == RemoteHarnessBotRead.REQUEST_BYTES)
    }
    case("coordinator-bounds-original-result-exactly-and-preserves-live-state") {
        val f = BotReadFake(); f.describe(capabilities)
        f.stream(RemoteHarnessOperations.sessionFollow("session-a"))
        val stopOutcomes = arrayListOf<RemoteHarnessOutcome>()
        val stop = f.owner.call(RemoteHarnessOperations.sessionCancel("session-a"), "stop-raw-bound", stopOutcomes::add)
        val compact = RemoteHarnessJSON.write(botResult(bots = listOf(botEntry(name = "Туслагч 助手 😀"))))
        fun padded(value: String, size: Int): String {
            val padding = size - value.toByteArray(Charsets.UTF_8).size
            check(padding >= 0 && value.startsWith('{'))
            return "{" + " ".repeat(padding) + value.substring(1)
        }
        val compactMany = RemoteHarnessJSON.write(botResult(bots = (0 until 100).map {
            botEntry("bot-$it-" + "a".repeat(250), "session-$it-" + "s".repeat(250))
        }))
        val expanded = compactMany.replace("a".repeat(250), "\\u0061".repeat(250)).replace("s".repeat(250), "\\u0073".repeat(250))
        check(compactMany.toByteArray(Charsets.UTF_8).size < RemoteHarnessBotRead.RESULT_BYTES &&
            expanded.toByteArray(Charsets.UTF_8).size > RemoteHarnessBotRead.RESULT_BYTES)
        val variants = listOf(
            padded(compact, RemoteHarnessBotRead.RESULT_BYTES + 1) to false,
            expanded to false,
            padded(compact, RemoteHarnessBotRead.RESULT_BYTES) to true,
            padded(compact.replace("workspace-a", "workspace-\\u0061"), RemoteHarnessBotRead.RESULT_BYTES) to true,
        )
        for ((raw, accepted) in variants) {
            val outcomes = arrayListOf<RemoteHarnessOutcome>()
            val id = f.owner.readBotRoster(outcomes::add)
            val carrier = f.rawBytes(id, raw)
            // A valid exact-limit result necessarily has a larger carrier; do not bound the whole frame.
            check(carrier.size > RemoteHarnessBotRead.RESULT_BYTES && carrier.size < RemoteHarnessBounds.FRAME_BYTES)
            check(f.owner.receive(f.context, carrier))
            val outcome = outcomes.single()
            check(outcome.kind == if (accepted) RemoteHarnessOutcomeKind.RESULT else RemoteHarnessOutcomeKind.LOCAL_FAILURE)
            check((outcome.botRoster != null) == accepted && outcome.frame == null && outcome.value == null)
            if (!accepted) check(outcome.errorCode == "invalid-response")
            check(f.owner.isReady() && f.owner.botReadSupported() && f.owner.streamCount() == 1 && f.owner.hostSlotCount() == 1 &&
                f.owner.pendingCount() == 1 && stopOutcomes.isEmpty() && f.invalidated.isEmpty() && f.journalCount == 1)
        }
        check(f.reply(stop, obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to obj("accepted" to RemoteHarnessJSON.BooleanValue(true)))))
        check(stopOutcomes.single().kind == RemoteHarnessOutcomeKind.STOP_RECEIPT)
    }
    case("reentrant-fast-reply-retains-typed-correlation") {
        val f = BotReadFake(); f.describe(capabilities)
        val outcomes = arrayListOf<RemoteHarnessOutcome>()
        f.onSend = { frame -> check(f.reply(frame.id, valid.rhRequired("response"))) }
        val id = f.owner.readBotRoster(outcomes::add)
        check(outcomes.single().wireRequestID == id && outcomes.single().botRoster != null && f.owner.pendingCount() == 0 && f.journalCount == 0)
    }
    println("BOT_READ_VERIFY_PASS fixtures=$fixtures cases=$cases")
}
