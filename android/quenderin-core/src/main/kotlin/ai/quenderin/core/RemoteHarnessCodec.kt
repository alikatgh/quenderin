package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str

/** Decrypted business frames at the pinned V3 carrier; no credential or crypto handling. */
class RemoteHarnessFrame internal constructor(
    val id: String, val type: String, val timestamp: Long, val payload: RemoteHarnessJSON.ObjectValue,
    val rawJSON: String, val requestID: String? = null, val eventName: String? = null,
    val streamID: String? = null,
) {
    override fun toString() = "RemoteHarnessFrame(redacted)"
}

object RemoteHarnessCodec {
    const val UPSTREAM_REVISION = "9a60e783ec1ceaff6116b0462a2863f07f602a55"
    const val REQUIRED_CAPABILITY = "harness.remote.v3"
    const val DESCRIBE = "harness.transport.describe"
    const val CALL = "harness.remote.call"
    const val OPEN = "harness.remote.stream.open"
    const val CLOSE = "harness.remote.stream.close"
    const val STREAM_FRAME = "harness.remote.frame"
    const val STREAM_CLOSED = "harness.remote.stream.closed"

    fun request(method: String, params: RemoteHarnessJSON, frameID: String, timestamp: Long): RemoteHarnessFrame {
        validateRequest(method, params)
        return decode(RemoteHarnessJSON.write(obj("v" to num(1), "id" to str(frameID), "type" to str("rpc.request"),
            "timestamp" to num(timestamp), "payload" to obj("method" to str(method), "params" to params))))
    }
    fun decode(bytes: ByteArray): RemoteHarnessFrame {
        // Decode with a strict UTF-8 decoder before retaining the exact original text.
        return decode(RemoteHarnessJSON.decodeUTF8(bytes))
    }
    fun decode(source: String): RemoteHarnessFrame {
        val root = RemoteHarnessJSON.parse(source).objectValue()
        root.rhFields("v", "id", "type", "timestamp", "payload")
        rhCheck(root.rhRequired("v").integerValue() == 1L, "unsupported-version")
        val id = root.rhString("id").also(::rhID)
        val type = root.rhString("type")
        val timestamp = root.rhRequired("timestamp").integerValue(true)
        val payload = root.rhRequired("payload") as? RemoteHarnessJSON.ObjectValue ?: throw RemoteHarnessException("invalid-type")
        val p = payload.values
        var requestID: String? = null
        var eventName: String? = null
        var streamID: String? = null
        when (type) {
            "rpc.request" -> { p.rhFields("method", "params"); validateRequest(p.rhString("method"), p.rhRequired("params")) }
            "rpc.response" -> { p.rhFields("requestId", "result"); requestID = p.rhString("requestId").also(::rhID); p.rhRequired("result") }
            "rpc.error" -> {
                p.rhFields("requestId", "code", "message", "retryable", "details")
                requestID = p.rhString("requestId").also(::rhID)
                rhCheck(p.rhString("code").isNotEmpty() && p.rhString("message").isNotEmpty())
                p["retryable"]?.booleanValue()
            }
            "event" -> {
                p.rhFields("event", "data", "seq", "sessionId")
                eventName = p.rhString("event")
                p["seq"]?.integerValue(); p["sessionId"]?.stringValue()?.let(::rhID)
                val data = p.rhRequired("data").objectValue()
                streamID = data.rhString("streamId").also(::rhID)
                when (eventName) {
                    STREAM_FRAME -> { data.rhFields("streamId", "hasValue", "value"); rhCheck(data.rhRequired("hasValue").booleanValue()) }
                    STREAM_CLOSED -> {
                        data.rhFields("streamId", "reason", "failure")
                        rhCheck(data.rhString("reason") in setOf("cancelled", "completed", "failed", "peer-disconnected"))
                        data["failure"]?.let(::validateFailure)
                    }
                    else -> throw RemoteHarnessException("unsupported-event")
                }
            }
            else -> throw RemoteHarnessException("unsupported-type")
        }
        return RemoteHarnessFrame(id, type, timestamp, payload, source, requestID, eventName, streamID)
    }

    /** Transport describe/open/close have raw results. Only CALL uses this nested Gateway result. */
    fun gatewayResult(value: RemoteHarnessJSON): RemoteHarnessGatewayResult {
        val result = value.objectValue()
        return if (result.rhRequired("ok").booleanValue()) {
            result.rhFields("ok", "value")
            RemoteHarnessGatewayResult(true, result["value"], null)
        } else {
            result.rhFields("ok", "error")
            val failure = result.rhRequired("error"); validateFailure(failure)
            RemoteHarnessGatewayResult(false, null, failure)
        }
    }
    internal fun validateFailure(value: RemoteHarnessJSON) {
        val failure = value.objectValue(); failure.rhFields("code", "message", "details")
        rhCheck(failure.rhString("code").isNotEmpty()); failure.rhString("message")
        failure.rhRequired("details").objectValue()
    }
    fun requireV3(value: RemoteHarnessJSON) {
        val capabilities = value.objectValue().rhRequired("capabilities") as? RemoteHarnessJSON.ArrayValue ?: throw RemoteHarnessException("invalid-capabilities")
        val names = capabilities.values.map { it.stringValue().also { name -> rhCheck(name.isNotEmpty(), "invalid-capabilities") } }
        rhCheck(names.size == names.toSet().size, "invalid-capabilities")
        rhCheck(REQUIRED_CAPABILITY in names && "harness.remote.v1" !in names, "unsupported-capability")
    }
    private fun validateRequest(method: String, paramsValue: RemoteHarnessJSON) {
        val params = paramsValue.objectValue()
        when (method) {
            DESCRIBE -> rhCheck(params.isEmpty(), "invalid-params")
            RemoteHarnessBotRead.METHOD -> RemoteHarnessBotRead.validateRequest(paramsValue)
            CLOSE -> { params.rhFields("streamId"); rhID(params.rhString("streamId")) }
            CALL, OPEN -> {
                if (method == OPEN) { params.rhFields("streamId", "endpoint", "payload"); rhID(params.rhString("streamId")) }
                else params.rhFields("endpoint", "payload")
                val payload = params.rhRequired("payload").objectValue(); payload.rhFields("args")
                RemoteHarnessOperations.fromWire(params.rhString("endpoint"), payload.rhRequired("args"), method == OPEN)
            }
            else -> throw RemoteHarnessException("unsupported-method")
        }
    }
}

class RemoteHarnessGatewayResult internal constructor(val ok: Boolean, val value: RemoteHarnessJSON?, val failure: RemoteHarnessJSON?) {
    override fun toString() = "RemoteHarnessGatewayResult(redacted)"
}

class RemoteHarnessOperation internal constructor(
    val endpoint: String, val args: RemoteHarnessJSON.ObjectValue, val streaming: Boolean,
    val mutating: Boolean, val sessionID: String?, val logicalCommandID: String?, val workspaceID: String? = null,
) {
    fun params(streamID: String? = null): RemoteHarnessJSON.ObjectValue {
        rhCheck(streaming == (streamID != null), "invalid-stream")
        return obj("streamId" to streamID?.let(::str), "endpoint" to str(endpoint), "payload" to obj("args" to args))
    }
    override fun toString() = "RemoteHarnessOperation(redacted)"
}

/** Fixed first-journey endpoints. No arbitrary command, transfer fallback, subscribe or sync API. */
object RemoteHarnessOperations {
    fun workspaceFollow() = operation("workspace/follow", obj(), true)
    fun sessionList() = operation("session/list", obj("_request" to obj()))
    fun sessionCreate(workspaceID: String) = operation("session/create", obj("request" to obj("workspaceId" to str(workspaceID))))
    fun sessionFollow(sessionID: String) = operation("session/follow", obj("request" to obj("address" to address(sessionID),
        "maxMessages" to num(60), "assistantStream" to RemoteHarnessJSON.BooleanValue(true))), true)
    fun sessionPage(sessionID: String, throughSeq: Long, beforeSeq: Long) = operation("session/page", obj("request" to obj(
        "address" to address(sessionID), "throughSeq" to num(throughSeq), "beforeSeq" to num(beforeSeq), "maxMessages" to num(60))))
    fun sessionPrompt(sessionID: String, logicalCommandID: String, text: String, clientTimeZone: String? = null) = operation("session/prompt",
        obj("request" to obj("requestId" to str(logicalCommandID), "sessionId" to str(sessionID), "mode" to str("queue"),
            "content" to RemoteHarnessJSON.ArrayValue(listOf(obj("type" to str("text"), "text" to str(text)))),
            "clientTimeZone" to clientTimeZone?.let(::str))))
    fun sessionCancel(sessionID: String) = operation("session/cancel", obj("request" to obj("sessionId" to str(sessionID))))
    fun sessionControl() = operation("session/control", obj(), true)
    fun approvalEvents() = operation("\$events", obj(), true)
    /** Wire encoding only. Coordinator rejects dispatch until a reviewed binding extension exists. */
    fun approvalEncodingOnly(clientID: String, eventID: String, allowedOnce: Boolean) = operation("\$events/result", obj(
        "clientId" to str(clientID), "eventId" to str(eventID), "outcome" to obj("kind" to str("result"), "value" to str(if (allowedOnce) "allowed-once" else "rejected"))))
    fun modelCatalog() = operation("session/modelCatalog", obj())
    fun approval(approval: RemoteHarnessClientApproval, allowedOnce: Boolean) = operation(RemoteHarnessClientApprovalGate.ENDPOINT,
        obj("binding" to approval.binding, "clientId" to str(approval.clientID), "outcome" to obj("kind" to str("result"),
            "value" to str(if (allowedOnce) "allowed-once" else "rejected"))))
    fun selectModel(sessionID: String, provider: String, model: String, reasoningEffort: String? = null) = operation("session/selectModel",
        obj("request" to obj("sessionId" to str(sessionID), "provider" to str(provider), "model" to str(model), "reasoningEffort" to reasoningEffort?.let(::str))))
    private fun address(sessionID: String) = obj("kind" to str("session"), "sessionId" to str(sessionID))
    private fun operation(endpoint: String, args: RemoteHarnessJSON, streaming: Boolean = false) = fromWire(endpoint, args, streaming)

    internal fun fromWire(endpoint: String, argsValue: RemoteHarnessJSON, streaming: Boolean): RemoteHarnessOperation {
        val args = argsValue.objectValue()
        val streams = setOf("workspace/follow", "session/follow", "session/control", "\$events")
        val calls = setOf("session/list", "session/create", "session/page", "session/prompt", "session/cancel", "session/modelCatalog", "session/selectModel", "\$events/result", RemoteHarnessClientApprovalGate.ENDPOINT)
        rhCheck(endpoint in if (streaming) streams else calls, "unsupported-endpoint")
        var sessionID: String? = null; var commandID: String? = null; var workspaceID: String? = null
        fun request(): Map<String, RemoteHarnessJSON> { args.rhFields("request"); return args.rhRequired("request").objectValue() }
        fun session(r: Map<String, RemoteHarnessJSON>) { sessionID = r.rhString("sessionId").also(::rhID) }
        fun address(r: Map<String, RemoteHarnessJSON>) {
            val a = r.rhRequired("address").objectValue(); a.rhFields("kind", "sessionId")
            rhCheck(a.rhString("kind") == "session", "unsupported-address"); session(a)
        }
        when (endpoint) {
            "workspace/follow", "session/control", "\$events", "session/modelCatalog" -> rhCheck(args.isEmpty(), "invalid-params")
            "session/list" -> { args.rhFields("_request"); rhCheck(args.rhRequired("_request").objectValue().isEmpty(), "invalid-params") }
            "session/create" -> { val r = request(); r.rhFields("workspaceId"); workspaceID = r.rhString("workspaceId").also(::rhID) }
            "session/follow" -> {
                val r = request(); r.rhFields("address", "maxMessages", "assistantStream"); address(r)
                rhCheck(r.rhRequired("maxMessages").integerValue() == 60L && r.rhRequired("assistantStream").booleanValue(), "invalid-params")
            }
            "session/page" -> {
                val r = request(); r.rhFields("address", "throughSeq", "beforeSeq", "maxMessages"); address(r)
                r.rhRequired("throughSeq").integerValue(); r.rhRequired("beforeSeq").integerValue()
                rhCheck(r.rhRequired("maxMessages").integerValue() == 60L, "invalid-params")
            }
            "session/prompt" -> {
                val r = request(); r.rhFields("requestId", "sessionId", "mode", "content", "clientTimeZone"); session(r)
                commandID = r.rhString("requestId").also(::rhID); rhCheck(r.rhString("mode") == "queue", "invalid-params")
                val content = r.rhRequired("content") as? RemoteHarnessJSON.ArrayValue ?: throw RemoteHarnessException("invalid-type")
                rhCheck(content.values.size == 1, "invalid-params")
                val text = content.values.single().objectValue(); text.rhFields("type", "text")
                rhCheck(text.rhString("type") == "text", "invalid-params")
                rhCheck(text.rhString("text").toByteArray(Charsets.UTF_8).size <= RemoteHarnessBounds.TEXT_BYTES, "text-limit")
                r["clientTimeZone"]?.stringValue()?.let { rhCheck(it == "UTC" || Regex("^[A-Za-z_]+/[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)?$").matches(it), "invalid-timezone") }
            }
            "session/cancel" -> { val r = request(); r.rhFields("sessionId"); session(r) }
            "session/selectModel" -> {
                val r = request(); r.rhFields("sessionId", "provider", "model", "reasoningEffort"); session(r)
                rhID(r.rhString("provider")); rhID(r.rhString("model")); r["reasoningEffort"]?.stringValue()?.let(::rhID)
            }
            "\$events/result" -> {
                args.rhFields("clientId", "eventId", "outcome"); rhID(args.rhString("clientId")); rhID(args.rhString("eventId"))
                val o = args.rhRequired("outcome").objectValue(); o.rhFields("kind", "value")
                rhCheck(o.rhString("kind") == "result" && o.rhString("value") in setOf("allowed-once", "rejected"), "invalid-params")
            }
            RemoteHarnessClientApprovalGate.ENDPOINT -> {
                args.rhFields("binding", "clientId", "outcome"); rhID(args.rhString("clientId"))
                val binding = args.rhRequired("binding").objectValue(); RemoteHarnessClientApprovalGate.validateBinding(binding)
                sessionID = binding.rhString("sessionId"); workspaceID = binding.rhString("workspaceId")
                val outcome = args.rhRequired("outcome").objectValue(); outcome.rhFields("kind", "value")
                rhCheck(outcome.rhString("kind") == "result" && outcome.rhString("value") in setOf("allowed-once", "rejected"), "invalid-params")
            }
        }
        return RemoteHarnessOperation(endpoint, argsValue as RemoteHarnessJSON.ObjectValue, streaming,
            endpoint in setOf("session/create", "session/prompt", "session/cancel", "session/selectModel", "\$events/result", RemoteHarnessClientApprovalGate.ENDPOINT), sessionID, commandID, workspaceID)
    }
}
