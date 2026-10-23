package ai.quenderin.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Fixed public messages. Neither remote response bodies nor exceptions become diagnostics. */
enum class DeepSeekFailure(val userMessage: String) {
    CREDENTIAL("Reconnect with a valid DeepSeek API key."),
    QUOTA("DeepSeek quota is exhausted. Check your DeepSeek account before sending again."),
    RATE_LIMIT("DeepSeek is rate limiting this account. Wait before sending again; no retry was made."),
    CONTEXT("This conversation exceeds DeepSeek's context limit. Start a new cloud conversation."),
    CONNECTION("Connection ended before a complete reply. No retry was made."),
    RESPONSE("DeepSeek returned an invalid or incomplete reply. No retry was made."),
    LIMIT("The reply exceeded this app's safety limits. No retry was made."),
    TIMEOUT("The request reached the two minute limit. No retry was made."),
    CANCELLED("Stopped. Partial output is saved separately and will not be sent as a completed reply."),
    STORAGE("Secure storage is unavailable. Reconnect after resolving device storage or lock settings."),
    MODEL("The selected model is unavailable. Reconnect or select another supported model."),
    BUSY("A request is already running."),
    INCOMPLETE("This conversation has an interrupted reply. Start a new cloud conversation before sending."),
}

class DeepSeekException(val failure: DeepSeekFailure) : Exception(failure.userMessage) {
    override fun toString() = "DeepSeekException(${failure.name})"
}

object DeepSeekCatalog {
    const val CATALOG_VERSION = "2026-10-23"
    const val ORIGIN = "https://api.deepseek.com"
    const val DEFAULT_MODEL = "deepseek-flash"
    val models: List<String> = listOf(DEFAULT_MODEL, "deepseek-v4-pro")
    const val MAX_BYTES = 8_388_608
    const val MAX_TEXT_BYTES = 1_048_576
    const val MAX_EVENTS = 65_536
    const val TIMEOUT_MS = 120_000L
    const val OUTPUT_TOKENS = 4_096L
    const val MAX_CONVERSATIONS = 30
    val capabilities = ProviderCapabilities(reasoning = true, toolCalls = true, documents = false, cancellation = true, usage = true)

    fun profile(reference: String) = ConnectionProfile.create("deepseek", ConnectionKind.DEEPSEEK,
        "DeepSeek", ORIGIN, credentialReference = reference)

    fun selection(model: String = DEFAULT_MODEL, effort: ReasoningEffort = ReasoningEffort.HIGH): ProviderSelection {
        if (model !in models) throw DeepSeekException(DeepSeekFailure.MODEL)
        return ProviderSelection("deepseek", model, effort)
    }
}

private fun dsString(s: String) = ConnectionJSON.StringValue(s)
private fun dsNumber(n: Long) = ConnectionJSON.NumberValue(n.toString())
private fun dsArray(values: List<ConnectionJSON.Value>) = ConnectionJSON.ArrayValue(values)
private fun dsObject(vararg entries: Pair<String, ConnectionJSON.Value?>) = ConnectionJSON.ObjectValue(
    linkedMapOf<String, ConnectionJSON.Value>().apply { entries.forEach { (k, v) -> if (v != null) put(k, v) } })
private fun dsRequire(condition: Boolean, failure: DeepSeekFailure = DeepSeekFailure.RESPONSE) {
    if (!condition) throw DeepSeekException(failure)
}
private inline fun <T> dsDecode(block: () -> T): T = try { block() }
    catch (e: NativeConnectionException) { throw DeepSeekException(DeepSeekFailure.RESPONSE) }

/** Dependency-free wire adapter. Documents are rejected rather than silently attached or omitted. */
object DeepSeekProtocol {
    fun requestBody(request: ProviderRequest): String = dsDecode {
        dsRequire(request.binding.kind == ConnectionKind.DEEPSEEK && request.binding.origin == DeepSeekCatalog.ORIGIN)
        dsRequire(request.selection.providerID == "deepseek" && request.selection.modelID in DeepSeekCatalog.models, DeepSeekFailure.MODEL)
        dsRequire(request.limits.maxOutputTokens in 1..DeepSeekCatalog.OUTPUT_TOKENS, DeepSeekFailure.LIMIT)
        dsRequire(request.tools.size <= request.limits.maxToolCalls, DeepSeekFailure.LIMIT)
        val messages = request.messages.map { message ->
            dsRequire(message.documents.isEmpty())
            dsObject("role" to dsString(message.role.wire), "content" to dsString(message.content),
                "reasoning_content" to message.reasoningContent?.let(::dsString),
                "tool_call_id" to message.toolCallID?.let(::dsString),
                "tool_calls" to message.toolCalls.takeIf { it.isNotEmpty() }?.let { calls -> dsArray(calls.map { call ->
                    dsObject("id" to dsString(call.id), "type" to dsString("function"),
                        "function" to dsObject("name" to dsString(call.name), "arguments" to dsString(call.argumentsJSON)))
                }) })
        }
        val body = dsObject("model" to dsString(request.selection.modelID), "messages" to dsArray(messages),
            "thinking" to dsObject("type" to dsString(if (request.selection.reasoningEffort == ReasoningEffort.OFF) "disabled" else "enabled")),
            "reasoning_effort" to request.selection.reasoningEffort.takeIf { it != ReasoningEffort.OFF }?.wire?.let(::dsString),
            "stream" to ConnectionJSON.BooleanValue(true),
            "stream_options" to dsObject("include_usage" to ConnectionJSON.BooleanValue(true)),
            "max_tokens" to dsNumber(request.limits.maxOutputTokens),
            "tools" to request.tools.takeIf { it.isNotEmpty() }?.let { tools -> dsArray(tools.map { tool ->
                dsObject("type" to dsString("function"), "function" to dsObject("name" to dsString(tool.name),
                    "description" to dsString(tool.description), "parameters" to ConnectionJSON.parse(tool.parametersJSON)))
            }) })
        ConnectionJSON.write(body).also { dsRequire(it.toByteArray(Charsets.UTF_8).size <= DeepSeekCatalog.MAX_BYTES, DeepSeekFailure.LIMIT) }
    }

    /** Validation is GET /models only: it never starts paid inference. Unknown model IDs are ignored. */
    fun availableModels(source: String): List<String> = dsDecode {
        val root = ConnectionJSON.parse(source).obj()
        val ids = root.array("data", 1_024).map { it.obj().string("id") }
        dsRequire(ids.size == ids.toSet().size)
        DeepSeekCatalog.models.filter { it in ids }.also { dsRequire(it.isNotEmpty(), DeepSeekFailure.MODEL) }
    }

    fun httpFailure(status: Int): DeepSeekFailure = when (status) {
        401, 403 -> DeepSeekFailure.CREDENTIAL
        402 -> DeepSeekFailure.QUOTA
        413, 422 -> DeepSeekFailure.CONTEXT
        429 -> DeepSeekFailure.RATE_LIMIT
        400 -> DeepSeekFailure.RESPONSE
        else -> DeepSeekFailure.CONNECTION
    }
}

/** Credentials are exchanged only at the vault/transport seam, never in profiles or transcripts. */
interface DeepSeekCredentialVault {
    fun save(key: CharArray): String
    fun <T> use(reference: String, action: (CharArray) -> T): T
    fun remove(reference: String)
    fun removeAll()
}

interface DeepSeekTransport {
    fun models(reference: String, cancellation: DeepSeekCancellation): List<String>
    fun stream(reference: String, request: ProviderRequest, cancellation: DeepSeekCancellation, onEvent: (ProviderEvent) -> Unit): DeepSeekReply
    fun cancel()
}

/** Register-before-execute admission. Cancellation before registration permanently rejects dispatch;
 * cancellation after registration cancels that exact call. A token is never reused for another call. */
class DeepSeekCancellation {
    private var cancelled = false
    private var registered = false
    private var cancelAction: (() -> Unit)? = null
    @Synchronized fun check() { if (cancelled) throw DeepSeekException(DeepSeekFailure.CANCELLED) }
    @Synchronized fun register(action: () -> Unit) {
        if (cancelled) { action(); throw DeepSeekException(DeepSeekFailure.CANCELLED) }
        dsRequire(!registered)
        registered = true; cancelAction = action
    }
    @Synchronized fun cancel() { cancelled = true; cancelAction?.invoke() }
    @Synchronized fun release() { cancelAction = null }
}

interface DeepSeekPersistence {
    fun readProfile(): ConnectionProfile?
    fun writeProfile(profile: ConnectionProfile?)
    fun readConversations(): List<DeepSeekConversation>
    fun writeConversation(conversation: DeepSeekConversation)
}

data class DeepSeekUsage(val inputTokens: Long, val outputTokens: Long) {
    override fun toString() = "DeepSeekUsage"
}
class DeepSeekReply(val text: String, val reasoning: String?, val toolCalls: List<ProviderToolCall>,
                    val usage: DeepSeekUsage?, val finish: String) {
    val complete: Boolean get() = finish == "stop" || finish == "tool_calls"
    override fun toString() = "DeepSeekReply(redacted)"
}

/** Incremental SSE framing over bytes, so split UTF-8 and CRLF boundaries remain exact.
 * A finish chunk AND [DONE] AND EOF are required before any completion is emitted. */
class DeepSeekStreamParser(private val messageID: String, private val maxToolCalls: Int,
                           private val onEvent: (ProviderEvent) -> Unit = {}) {
    private val line = ByteArrayOutputStream()
    private val data = StringBuilder()
    private var dataBytes = 0
    private val answer = StringBuilder()
    private val reasoning = StringBuilder()
    private var answerBytes = 0
    private var reasoningBytes = 0
    private var bytes = 0L
    private var events = 0
    private var skipLF = false
    private var firstLine = true
    private var done = false
    private var closed = false
    private var finishReason: String? = null
    private var usage: DeepSeekUsage? = null
    private var streamID: String? = null
    private val tools = sortedMapOf<Int, ToolParts>()
    private class ToolParts(var id: String? = null, var name: String? = null,
                          val arguments: StringBuilder = StringBuilder(), var bytes: Int = 0)

    init { dsRequire(maxToolCalls in 0..NativeConnectionBounds.MAX_TOOL_CALLS, DeepSeekFailure.LIMIT) }

    fun feed(chunk: ByteArray, length: Int = chunk.size) = dsDecode {
        dsRequire(!closed && length in 0..chunk.size)
        bytes += length
        dsRequire(bytes <= DeepSeekCatalog.MAX_BYTES, DeepSeekFailure.LIMIT)
        for (i in 0 until length) {
            val byte = chunk[i].toInt() and 255
            if (skipLF) { skipLF = false; if (byte == 10) continue }
            when (byte) {
                13 -> { flushLine(); skipLF = true }
                10 -> flushLine()
                else -> { dsRequire(line.size() < DeepSeekCatalog.MAX_TEXT_BYTES, DeepSeekFailure.LIMIT); line.write(byte) }
            }
        }
    }

    fun end(): DeepSeekReply = dsDecode {
        dsRequire(!closed)
        closed = true
        // An unterminated line/event is never promoted to a successful response.
        dsRequire(line.size() == 0 && data.isEmpty() && done && finishReason != null)
        val calls = tools.map { (_, part) ->
            dsRequire(!part.id.isNullOrBlank() && !part.name.isNullOrBlank())
            dsRequire(ConnectionJSON.parse(part.arguments.toString()) is ConnectionJSON.ObjectValue)
            ProviderToolCall(part.id!!, part.name!!, part.arguments.toString())
        }
        dsRequire(tools.keys.toList() == (0 until tools.size).toList())
        dsRequire(calls.map { it.id }.distinct().size == calls.size)
        val reason = finishReason!!
        dsRequire((reason == "tool_calls") == calls.isNotEmpty())
        val reply = DeepSeekReply(answer.toString(), reasoning.toString().takeIf { it.isNotEmpty() }, calls, usage, reason)
        onEvent(ProviderEvent.Completed(when (reason) {
            "tool_calls" -> ProviderCompletionReason.TOOL_CALLS
            "length" -> ProviderCompletionReason.OUTPUT_LIMIT
            else -> ProviderCompletionReason.END
        }))
        reply
    }

    private fun flushLine() {
        val decoded = try { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(line.toByteArray())).toString() }
            catch (_: Exception) { throw DeepSeekException(DeepSeekFailure.RESPONSE) }
        line.reset()
        val value = if (firstLine) decoded.removePrefix("\uFEFF") else decoded
        firstLine = false
        if (value.isEmpty()) {
            dsRequire(++events <= DeepSeekCatalog.MAX_EVENTS, DeepSeekFailure.LIMIT)
            if (data.isNotEmpty()) {
                val event = data.toString().dropLast(1)
                data.setLength(0); dataBytes = 0
                parseEvent(event)
            }
        } else if (!value.startsWith(':')) {
            val field = value.substringBefore(':')
            if (field == "data") {
                val payload = if (':' in value) value.substringAfter(':').removePrefix(" ") else ""
                dataBytes += payload.toByteArray(Charsets.UTF_8).size + 1
                dsRequire(dataBytes <= DeepSeekCatalog.MAX_TEXT_BYTES,
                    DeepSeekFailure.LIMIT)
                data.append(payload).append('\n')
            }
        }
    }

    private fun parseEvent(source: String) {
        dsRequire(!done)
        if (source == "[DONE]") { dsRequire(finishReason != null); done = true; return }
        val root = ConnectionJSON.parse(source).obj()
        dsRequire(!root.containsKey("error"))
        root["id"]?.let { value ->
            val id = value.string()
            dsRequire(id.isNotEmpty() && (streamID == null || streamID == id))
            streamID = id
        }
        root["usage"]?.takeUnless { it == ConnectionJSON.NullValue }?.let { value ->
            val u = value.obj()
            dsRequire(usage == null)
            usage = DeepSeekUsage(u.required("prompt_tokens").integer(), u.required("completion_tokens").integer())
            dsRequire(usage!!.outputTokens <= DeepSeekCatalog.OUTPUT_TOKENS, DeepSeekFailure.LIMIT)
            onEvent(ProviderEvent.Usage(usage!!.inputTokens, usage!!.outputTokens))
        }
        val choices = root.array("choices", 1)
        if (choices.isEmpty()) { dsRequire(usage != null && finishReason != null); return }
        dsRequire(finishReason == null)
        val choice = choices.single().obj()
        dsRequire(choice.required("index").integer() == 0L)
        val delta = choice.required("delta").obj()
        delta["role"]?.let { dsRequire(it.string() == "assistant") }
        delta["content"]?.takeUnless { it == ConnectionJSON.NullValue }?.let {
            val fragment = it.string(); answerBytes += fragment.toByteArray(Charsets.UTF_8).size
            dsRequire(answerBytes <= DeepSeekCatalog.MAX_TEXT_BYTES, DeepSeekFailure.LIMIT)
            answer.append(fragment); onEvent(ProviderEvent.Text(messageID, fragment))
        }
        delta["reasoning_content"]?.takeUnless { it == ConnectionJSON.NullValue }?.let {
            val fragment = it.string(); reasoningBytes += fragment.toByteArray(Charsets.UTF_8).size
            dsRequire(reasoningBytes <= DeepSeekCatalog.MAX_TEXT_BYTES, DeepSeekFailure.LIMIT)
            reasoning.append(fragment); onEvent(ProviderEvent.Reasoning(messageID, fragment))
        }
        delta["tool_calls"]?.takeUnless { it == ConnectionJSON.NullValue }?.let { value ->
            val fragments = (value as? ConnectionJSON.ArrayValue)?.values ?: throw DeepSeekException(DeepSeekFailure.RESPONSE)
            dsRequire(fragments.size <= maxToolCalls, DeepSeekFailure.LIMIT)
            for (fragment in fragments) {
                val call = fragment.obj(); val index = call.required("index").integer()
                dsRequire(index < maxToolCalls, DeepSeekFailure.LIMIT)
                val part = tools.getOrPut(index.toInt()) { ToolParts() }
                val id = call.optionalString("id")
                id?.let { dsRequire(part.id == null || part.id == it); part.id = it }
                call["type"]?.let { dsRequire(it.string() == "function") }
                val function = call["function"]?.obj()
                val name = function?.optionalString("name")
                name?.let { dsRequire(part.name == null || part.name == it); part.name = it }
                val arguments = function?.optionalString("arguments") ?: ""
                part.bytes += arguments.toByteArray(Charsets.UTF_8).size
                dsRequire(part.bytes <= DeepSeekCatalog.MAX_TEXT_BYTES,
                    DeepSeekFailure.LIMIT)
                part.arguments.append(arguments)
                onEvent(ProviderEvent.ToolCallFragment(messageID, id, index.toInt(), name, arguments))
            }
        }
        choice["finish_reason"]?.takeUnless { it == ConnectionJSON.NullValue }?.let {
            val reason = it.string()
            dsRequire(reason in setOf("stop", "length", "content_filter", "tool_calls", "insufficient_system_resource", "aborted"))
            dsRequire(reason !in setOf("content_filter", "insufficient_system_resource", "aborted"))
            finishReason = reason
        }
    }
}

/** One destination-bound cloud thread. Incomplete output stays outside provider history on disk. */
class DeepSeekConversation private constructor(var envelope: ConversationEnvelope, var partial: String,
                                              var partialReasoning: String, var incomplete: Boolean) {
    private var activeMessageID: String? = null
    val running: Boolean get() = activeMessageID != null
    fun begin(profile: ConnectionProfile, text: String, selection: ProviderSelection, nowMs: Long, id: String): ProviderRequest {
        if (running) throw DeepSeekException(DeepSeekFailure.BUSY)
        if (incomplete) throw DeepSeekException(DeepSeekFailure.INCOMPLETE)
        dsRequire(text.isNotBlank())
        envelope.binding.requireMatches(profile)
        val next = ConversationEnvelope(envelope.conversationID, envelope.binding,
            envelope.messages + ProviderMessage("user-$id", ProviderRole.USER, text), selection)
        val request = ProviderRequest("request-$id", next, profile, DeepSeekCatalog.capabilities, emptyList(),
            ProviderRequestLimits(DeepSeekCatalog.OUTPUT_TOKENS, 0, nowMs + DeepSeekCatalog.TIMEOUT_MS), nowMs)
        DeepSeekProtocol.requestBody(request) // All encoding/size checks precede persistence and dispatch.
        envelope = next; partial = ""; partialReasoning = ""; incomplete = true; activeMessageID = "assistant-$id"
        return request
    }
    fun event(event: ProviderEvent) {
        if (!running) return
        when (event) {
            is ProviderEvent.Text -> if (event.messageID == activeMessageID) partial += event.delta
            is ProviderEvent.Reasoning -> if (event.messageID == activeMessageID) partialReasoning += event.delta
            else -> Unit
        }
    }
    fun complete(reply: DeepSeekReply) {
        val id = activeMessageID ?: return
        if (reply.complete) {
            envelope = ConversationEnvelope(envelope.conversationID, envelope.binding,
                envelope.messages + ProviderMessage(id, ProviderRole.ASSISTANT, reply.text, reply.reasoning, reply.toolCalls), envelope.selection)
            partial = ""; partialReasoning = ""; incomplete = false
        } else { partial = reply.text; partialReasoning = reply.reasoning ?: ""; incomplete = true }
        activeMessageID = null
    }
    fun interrupt() { activeMessageID = null; incomplete = true }
    fun encode(): String = ConnectionJSON.write(dsObject("schemaVersion" to dsNumber(1),
        "envelope" to ConnectionJSON.parse(NativeConnectionsCodec.encodeEnvelope(envelope)), "partial" to dsString(partial),
        "partialReasoning" to dsString(partialReasoning), "incomplete" to ConnectionJSON.BooleanValue(incomplete)))
    override fun toString() = "DeepSeekConversation(redacted)"
    companion object {
        fun new(profile: ConnectionProfile, id: String, selection: ProviderSelection) = DeepSeekConversation(
            ConversationEnvelope(id, ConversationBinding.from(profile), emptyList(), selection), "", "", false)
        fun decode(source: String): DeepSeekConversation = dsDecode {
            val o = ConnectionJSON.parse(source).obj()
            fields(o, "schemaVersion", "envelope", "partial", "partialReasoning", "incomplete")
            dsRequire(o.required("schemaVersion").integer() == 1L)
            val envelope = NativeConnectionsCodec.decodeEnvelope(ConnectionJSON.write(o.required("envelope")))
            dsRequire(envelope.binding.kind == ConnectionKind.DEEPSEEK && envelope.remoteSession == null)
            val incomplete = (o.required("incomplete") as? ConnectionJSON.BooleanValue)?.value ?: throw DeepSeekException(DeepSeekFailure.RESPONSE)
            DeepSeekConversation(envelope, o.string("partial"), o.string("partialReasoning"), incomplete)
        }
    }
}
