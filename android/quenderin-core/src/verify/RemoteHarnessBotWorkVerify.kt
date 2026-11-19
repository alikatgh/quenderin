package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.io.File

private fun workCanonical(value: RemoteHarnessJSON): String {
    fun sorted(v: RemoteHarnessJSON): RemoteHarnessJSON = when (v) {
        is RemoteHarnessJSON.ObjectValue -> RemoteHarnessJSON.ObjectValue(v.values.toSortedMap().mapValues { sorted(it.value) })
        is RemoteHarnessJSON.ArrayValue -> RemoteHarnessJSON.ArrayValue(v.values.map(::sorted))
        else -> v
    }
    return RemoteHarnessJSON.write(sorted(value))
}
private fun workReject(block: () -> Unit) {
    var rejected = false
    try { block() } catch (_: RemoteHarnessException) { rejected = true }
    check(rejected)
}
private fun submission(params: RemoteHarnessJSON): RemoteHarnessBotSubmission {
    RemoteHarnessBotWork.validateRequest(params)
    val p = params.objectValue().rhRequired("body").objectValue().rhRequired("payload").objectValue()
    return RemoteHarnessBotWork.submission(p.rhString("workspaceId"), p.rhString("botId"), p.rhString("expectedSessionId"),
        p.rhRequired("expectedRevision").integerValue(), p.rhString("commandId"), p.rhString("text"))
}
private class WorkOwner {
    var now = 1L
    var context = RemoteHarnessAuthenticatedContext(RemoteHarnessTransportBinding("profile-a", "https://relay.example", "host-a", "a".repeat(64),
        "workspace-a"), "device-a", "connection-a", 1, "session-a")
    val sent = arrayListOf<RemoteHarnessFrame>()
    val reservations = arrayListOf<RemoteHarnessPreparedMutation>()
    var journalAllowed = true
    var sendThrows = false
    val coordinator = RemoteHarnessCoordinator(object : RemoteHarnessDecryptedPort {
        override fun send(context: RemoteHarnessAuthenticatedContext, frame: ByteArray) {
            check(context == this@WorkOwner.context)
            sent.add(RemoteHarnessCodec.decode(frame))
            if (sendThrows) error("SYNTHETIC_PRIVATE_SEND")
        }
        override fun invalidate(context: RemoteHarnessAuthenticatedContext) {}
    }, object : RemoteHarnessClock {
        override fun epochMilliseconds() = now
        override fun monotonicMilliseconds() = now
    }, RemoteHarnessMutationJournal { reservations.add(it); journalAllowed })
    init { coordinator.beginConnection(context) }
    fun reply(id: String, result: RemoteHarnessJSON, error: Boolean = false, source: RemoteHarnessAuthenticatedContext = context) =
        coordinator.receive(source, RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("response-a"), "type" to str(if (error) "rpc.error" else "rpc.response"),
            "timestamp" to num(now), "payload" to if (error) obj("requestId" to str(id), "code" to str("UNAVAILABLE"), "message" to str("synthetic"))
                else obj("requestId" to str(id), "result" to result))).toByteArray(Charsets.UTF_8))
    fun describe(capabilities: List<String>) {
        val id = coordinator.describe {}
        reply(id, obj("capabilities" to RemoteHarnessJSON.ArrayValue(capabilities.map(::str))))
        check(coordinator.isReady())
    }
}

/** Frozen protocol fixtures and isolated coordinator checks; no network, models or native runtime. */
fun main(args: Array<String>) {
    val file = File(args.single()); check(file.length() <= RemoteHarnessBounds.FRAME_BYTES)
    val root = RemoteHarnessJSON.parse(file.readBytes()).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L)
    val valid = root.rhRequired("valid").objectValue()
    val request = valid.rhRequired("submit")
    val sealed = submission(request)
    val capabilities = (root.rhRequired("capabilities") as RemoteHarnessJSON.ArrayValue).values.map { it.stringValue() }
    var cases = 0
    fun case(name: String, body: () -> Unit) {
        try { body() } catch (_: Throwable) { throw IllegalStateException("BOT_WORK_CASE_FAIL $name") }
        cases++; println("BOT_WORK_CASE_PASS $name")
    }
    case("shared-submit") { check(workCanonical(sealed.params) == workCanonical(request)); check(sealed.toString() == "RemoteHarnessBotSubmission(redacted)") }
    case("shared-status") { check(workCanonical(RemoteHarnessBotWork.command(sealed.workspaceID, sealed.botID, sealed.commandID)) == workCanonical(valid.rhRequired("status"))) }
    for (name in listOf("accepted", "rejected", "uncertain", "notFound", "payloadConflict")) case("shared-$name") {
        val receipt = RemoteHarnessBotWork.receipt(valid.rhRequired(name), sealed)
        check(receipt.toString() == "RemoteHarnessBotCommandReceipt(redacted)" && receipt.state.wire == if (name == "payloadConflict") "rejected" else name)
    }
    for (row in (root.rhRequired("invalidRequests") as RemoteHarnessJSON.ArrayValue).values) {
        val p = row.objectValue(); case("request-${p.rhString("id")}") { workReject { RemoteHarnessBotWork.validateRequest(p.rhRequired("params"), sealed.workspaceID) } }
    }
    for (row in (root.rhRequired("invalidResponses") as RemoteHarnessJSON.ArrayValue).values) {
        val p = row.objectValue(); case("response-${p.rhString("id")}") { workReject { RemoteHarnessBotWork.receipt(p.rhRequired("result"), p["request"]?.let(::submission) ?: sealed) } }
    }
    for (row in (root.rhRequired("generatedLimits") as RemoteHarnessJSON.ArrayValue).values) {
        val p = row.objectValue(); case("limit-${p.rhString("id")}") {
            val body = request.objectValue().rhRequired("body").objectValue(); val payload = body.rhRequired("payload").objectValue()
            val changed = RemoteHarnessJSON.ObjectValue(request.objectValue() + ("body" to RemoteHarnessJSON.ObjectValue(body + ("payload" to
                RemoteHarnessJSON.ObjectValue(payload + (p.rhString("field") to str(p.rhString("value").repeat(p.rhRequired("count").integerValue().toInt()))))))))
            if (p.rhRequired("expectedValid").booleanValue()) RemoteHarnessBotWork.validateRequest(changed) else workReject { RemoteHarnessBotWork.validateRequest(changed) }
        }
    }
    case("payload-conflict-is-distinct") {
        val conflict = root.rhRequired("payloadConflict").objectValue()
        check(submission(conflict.rhRequired("original")).digest != submission(conflict.rhRequired("changed")).digest)
        check(RemoteHarnessBotWork.receipt(conflict.rhRequired("response"), sealed).reason == "payloadConflict")
        check(RemoteHarnessBotWork.receipt(conflict.rhRequired("originalReceiptAfterConflict"), sealed).state == RemoteHarnessBotCommandState.ACCEPTED)
    }
    case("server-context-is-not-request-data") {
        val scope = root.rhRequired("scopeIsolation").objectValue()
        RemoteHarnessBotWork.validateRequest(scope.rhRequired("request"), sealed.workspaceID)
        check(scope.rhRequired("serverContextIsNeverTransmitted").booleanValue())
        val payload = scope.rhRequired("request").objectValue().rhRequired("body").objectValue().rhRequired("payload").objectValue()
        check("hostDeviceId" !in payload && "peerDeviceId" !in payload)
        check(RemoteHarnessBotWork.receipt(scope.rhRequired("responseInOtherContext"), sealed).state == RemoteHarnessBotCommandState.NOT_FOUND)
    }
    for (missing in listOf(RemoteHarnessBotWork.CAPABILITY, RemoteHarnessBotRead.CAPABILITY, RemoteHarnessBotRead.CARRIER_CAPABILITY)) case("capability-$missing") {
        val f = WorkOwner(); f.describe(capabilities.filter { it != missing }); val before = f.sent.size
        workReject { f.coordinator.submitBot(sealed) {} }
        workReject { f.coordinator.botCommand(sealed.botID, sealed.commandID) {} }
        check(f.sent.size == before && f.reservations.isEmpty())
    }
    case("accepted-is-admission") {
        val f = WorkOwner(); f.describe(capabilities); var outcome: RemoteHarnessOutcome? = null
        val id = f.coordinator.submitBot(sealed) { outcome = it }
        check(f.reservations.single().botSubmission?.digest == sealed.digest && f.sent.last().payload.values.rhString("method") == RemoteHarnessBotRead.METHOD)
        f.reply(id, valid.rhRequired("accepted"))
        check(outcome?.kind == RemoteHarnessOutcomeKind.RESULT && outcome?.botCommand?.state == RemoteHarnessBotCommandState.ACCEPTED)
    }
    case("journal-before-send") {
        val f = WorkOwner(); f.describe(capabilities); f.journalAllowed = false; val before = f.sent.size
        workReject { f.coordinator.submitBot(sealed) {} }
        check(f.reservations.size == 1 && f.sent.size == before && f.coordinator.pendingCount() == 0)
    }
    case("lost-ack-timeout-no-replay") {
        val f = WorkOwner(); f.describe(capabilities); val outcomes = arrayListOf<RemoteHarnessOutcome>()
        f.coordinator.submitBot(sealed) { outcomes.add(it) }; val before = f.sent.size
        f.now += RemoteHarnessBounds.DEADLINE_MS; f.coordinator.expire(); f.coordinator.expire()
        check(outcomes.single().kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && f.sent.size == before)
        f.coordinator.disconnected(f.context); check(outcomes.size == 1)
    }
    case("send-failure-uncertain") {
        val f = WorkOwner(); f.describe(capabilities); f.sendThrows = true; var outcome: RemoteHarnessOutcome? = null
        f.coordinator.submitBot(sealed) { outcome = it }
        check(outcome?.kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && f.reservations.size == 1)
    }
    case("retargeted-receipt-uncertain") {
        val f = WorkOwner(); f.describe(capabilities); var outcome: RemoteHarnessOutcome? = null
        val id = f.coordinator.submitBot(sealed) { outcome = it }
        val rows = (root.rhRequired("invalidResponses") as RemoteHarnessJSON.ArrayValue).values
        f.reply(id, rows.single { it.objectValue().rhString("id") == "retargeted-session" }.objectValue().rhRequired("result"))
        check(outcome?.kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && outcome?.botCommand == null)
    }
    case("rpc-error-mutation-uncertain") {
        val f = WorkOwner(); f.describe(capabilities); var outcome: RemoteHarnessOutcome? = null
        val id = f.coordinator.submitBot(sealed) { outcome = it }; f.reply(id, RemoteHarnessJSON.NullValue, error = true)
        check(outcome?.kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && outcome?.botCommand == null)
    }
    case("query-is-read-only") {
        val f = WorkOwner(); f.describe(capabilities); var outcome: RemoteHarnessOutcome? = null
        val id = f.coordinator.botCommand(sealed.botID, sealed.commandID) { outcome = it }
        f.reply(id, valid.rhRequired("notFound"))
        check(f.reservations.isEmpty() && outcome?.botCommand?.state == RemoteHarnessBotCommandState.NOT_FOUND)
    }
    case("part-binding-and-stale-generation") {
        val f = WorkOwner(); f.describe(capabilities); val before = f.sent.size
        workReject { f.coordinator.submitBot(RemoteHarnessBotWork.submission(sealed.workspaceID, sealed.botID, "part-b", sealed.revision, sealed.commandID, sealed.text)) {} }
        check(f.sent.size == before)
        val old = f.context; val id = f.coordinator.botCommand(sealed.botID, sealed.commandID) {}
        f.context = old.copy(connectionID = "connection-b", generation = 2); f.coordinator.beginConnection(f.context)
        check(!f.reply(id, valid.rhRequired("accepted"), source = old))
    }
    println("Bot work verification passed: $cases synthetic cases; no live Host or model.")
}
