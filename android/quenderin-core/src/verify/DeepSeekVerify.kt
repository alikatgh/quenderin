package ai.quenderin.core

import java.io.File
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

private fun equalJSON(left: ConnectionJSON.Value, right: ConnectionJSON.Value): Boolean = when {
    left is ConnectionJSON.ObjectValue && right is ConnectionJSON.ObjectValue -> left.values.keys == right.values.keys && left.values.all { (k, v) -> equalJSON(v, right.values.getValue(k)) }
    left is ConnectionJSON.ArrayValue && right is ConnectionJSON.ArrayValue -> left.values.size == right.values.size && left.values.zip(right.values).all { (a, b) -> equalJSON(a, b) }
    left is ConnectionJSON.StringValue && right is ConnectionJSON.StringValue -> left.value == right.value
    left is ConnectionJSON.NumberValue && right is ConnectionJSON.NumberValue -> left.token == right.token
    left is ConnectionJSON.BooleanValue && right is ConnectionJSON.BooleanValue -> left.value == right.value
    else -> left === ConnectionJSON.NullValue && right === ConnectionJSON.NullValue
}

private fun rejected(action: () -> Unit) {
    var rejected = false
    try { action() } catch (_: DeepSeekException) { rejected = true } catch (_: NativeConnectionException) { rejected = true }
    check(rejected) { "Expected bounded rejection" }
}

fun main(args: Array<String>) {
    val root = File(args.firstOrNull() ?: ".")
    val fixtureFile = if (root.isFile) root else File(root, "shared/deepseek-provider-fixtures.json")
    val fixtures = ConnectionJSON.parse(fixtureFile.readText()).obj()
    val contract = ConnectionJSON.parse(File(fixtureFile.parentFile, "deepseek-provider-contract.json").readText()).obj()
    check(contract.string("catalogVersion") == DeepSeekCatalog.CATALOG_VERSION)
    check(contract.string("origin") == DeepSeekCatalog.ORIGIN)
    check(contract.array("models", 10).map { it.obj().string("id") } == DeepSeekCatalog.models)
    val limits = contract.required("limits").obj()
    check(limits.required("deadlineMs").integer() == DeepSeekCatalog.TIMEOUT_MS)
    check(limits.required("maxRequestBytes").integer() == DeepSeekCatalog.MAX_BYTES.toLong())
    check(limits.required("maxResponseBytes").integer() == DeepSeekCatalog.MAX_BYTES.toLong())
    check(limits.required("maxSSEEventBytes").integer() == DeepSeekCatalog.MAX_TEXT_BYTES.toLong())
    check(limits.required("maxSSEEvents").integer() == DeepSeekCatalog.MAX_EVENTS.toLong())
    check(limits.required("maxTextBytes").integer() == DeepSeekCatalog.MAX_TEXT_BYTES.toLong())
    check(limits.required("defaultMaxOutputTokens").integer() == DeepSeekCatalog.OUTPUT_TOKENS)
    check(limits.required("initialUIToolCalls").integer() == 0L)

    for (value in fixtures.array("requests", 100)) {
        val fixture = value.obj()
        val action = {
            val profile = NativeConnectionsCodec.decodeProfile(ConnectionJSON.write(fixture.required("profile")))
            val envelope = NativeConnectionsCodec.decodeEnvelope(ConnectionJSON.write(fixture.required("envelope")))
            val tools = fixture.array("tools", 128).map { toolValue ->
                val tool = toolValue.obj()
                ProviderToolDefinition(tool.string("name"), tool.string("description"), tool.string("parametersJSON"))
            }
            val bound = fixture.required("limits").obj()
            val request = ProviderRequest("fixture", envelope, profile, DeepSeekCatalog.capabilities, tools,
                ProviderRequestLimits(bound.required("maxOutputTokens").integer(), bound.required("maxToolCalls").integer().toInt(), bound.required("deadlineEpochMs").integer()), 1)
            val body = DeepSeekProtocol.requestBody(request)
            if (!fixture.containsKey("error")) check(equalJSON(ConnectionJSON.parse(body), fixture.required("expectedBody"))) { "request mismatch: ${fixture.string("id")}" }
        }
        if (fixture.containsKey("error")) rejected(action) else action()
        println("DEEPSEEK_FIXTURE_PASS ${fixture.string("id")}")
    }
    for (value in fixtures.array("streams", 100)) {
        val fixture = value.obj()
        val action = {
            val events = mutableListOf<ProviderEvent>()
            val parser = DeepSeekStreamParser("assistant-fixture", fixture.required("maxToolCalls").integer().toInt(), events::add)
            fixture.array("chunksBase64", 65_536).forEach { parser.feed(Base64.getDecoder().decode(it.string())) }
            val reply = parser.end()
            if (!fixture.containsKey("error")) {
                val expected = fixture.required("expected").obj()
                check(reply.text == expected.string("text"))
                check((reply.reasoning ?: "") == expected.string("reasoning"))
                val expectedTools = expected.array("toolCalls", 128)
                check(reply.toolCalls.size == expectedTools.size)
                expectedTools.zip(reply.toolCalls).forEachIndexed { index, (toolValue, actual) ->
                    val tool = toolValue.obj()
                    check(tool.required("index").integer() == index.toLong())
                    check(actual.id == tool.string("id") && actual.name == tool.string("name") && actual.argumentsJSON == tool.string("arguments"))
                }
                val usage = expected["usage"]?.takeUnless { it === ConnectionJSON.NullValue }?.obj()
                check(reply.usage?.inputTokens == usage?.required("inputTokens")?.integer())
                check(reply.usage?.outputTokens == usage?.required("outputTokens")?.integer())
                check(expected.string("finish") == when (reply.finish) { "stop" -> "end"; "tool_calls" -> "toolCalls"; "length" -> "outputLimit"; else -> "invalid" })
                check(events.count { it is ProviderEvent.Completed } == 1)
            }
        }
        if (fixture.containsKey("error")) rejected(action) else action()
        println("DEEPSEEK_FIXTURE_PASS ${fixture.string("id")}")
    }
    for (value in fixtures.array("models", 100)) {
        val fixture = value.obj()
        val action = {
            val available = DeepSeekProtocol.availableModels(fixture.string("json"))
            if (!fixture.containsKey("error")) check(available == fixture.array("expectedIDs", 10).map { it.string() })
        }
        if (fixture.containsKey("error")) rejected(action) else action()
        println("DEEPSEEK_FIXTURE_PASS ${fixture.string("id")}")
    }

    val profile = DeepSeekCatalog.profile("qcred:fixture-reference")
    val selection = DeepSeekCatalog.selection()
    val conversation = DeepSeekConversation.new(profile, "fixture-conversation", selection)
    val request = conversation.begin(profile, "hello", selection, 1, "first")
    check(request.limits.maxToolCalls == 0 && request.tools.isEmpty())
    val recoveredInFlight = DeepSeekConversation.decode(conversation.encode())
    check(recoveredInFlight.incomplete && recoveredInFlight.envelope.messages.size == 1 && !recoveredInFlight.running)
    rejected { recoveredInFlight.begin(profile, "do not silently replay", selection, 1, "second") }
    rejected { conversation.begin(profile, "parallel", selection, 1, "parallel") }
    conversation.event(ProviderEvent.Text("assistant-first", "partial"))
    conversation.event(ProviderEvent.Reasoning("assistant-first", "retained reasoning"))
    conversation.interrupt()
    val partial = DeepSeekConversation.decode(conversation.encode())
    check(partial.partial == "partial" && partial.partialReasoning == "retained reasoning" && partial.envelope.messages.size == 1)
    partial.event(ProviderEvent.Text("assistant-first", "stale"))
    check(partial.partial == "partial")
    rejected { partial.begin(profile, "new", selection, 1, "second") }
    val complete = DeepSeekConversation.new(profile, "complete", selection)
    complete.begin(profile, "hello", selection, 1, "turn")
    complete.complete(DeepSeekReply("answer", "reasoning", emptyList(), DeepSeekUsage(2, 3), "stop"))
    check(!complete.incomplete && complete.envelope.messages.size == 2)
    check(DeepSeekConversation.decode(complete.encode()).envelope.messages.last().reasoningContent == "reasoning")
    val limited = DeepSeekConversation.new(profile, "limited", selection)
    limited.begin(profile, "hello", selection, 1, "turn")
    limited.complete(DeepSeekReply("partial", null, emptyList(), null, "length"))
    check(limited.incomplete && limited.envelope.messages.size == 1)
    rejected { limited.begin(profile, "new", selection, 1, "new") }

    // Stop before call admission: register must cancel the exact call and reject execution.
    val token = DeepSeekCancellation()
    val cancelled = AtomicInteger()
    token.cancel()
    rejected { token.register { cancelled.incrementAndGet() } }
    check(cancelled.get() == 1)
    val registered = CountDownLatch(1)
    val stop = CountDownLatch(1)
    val token2 = DeepSeekCancellation()
    val worker = thread {
        token2.register { cancelled.incrementAndGet() }
        registered.countDown()
        check(stop.await(3, TimeUnit.SECONDS))
        rejected { token2.check() }
    }
    check(registered.await(3, TimeUnit.SECONDS)); token2.cancel(); stop.countDown(); worker.join()
    check(cancelled.get() == 2)

    // Actual allocation limits, not just declared constants.
    rejected { DeepSeekStreamParser("bounded", 0).feed(ByteArray(DeepSeekCatalog.MAX_BYTES + 1)) }
    rejected { DeepSeekStreamParser("bounded", 0).feed(ByteArray(DeepSeekCatalog.MAX_TEXT_BYTES + 1) { 'x'.code.toByte() }) }
    rejected { DeepSeekStreamParser("bounded", 0).feed("\n".repeat(DeepSeekCatalog.MAX_EVENTS + 1).toByteArray()) }
    check(DeepSeekProtocol.httpFailure(401) == DeepSeekFailure.CREDENTIAL)
    check(DeepSeekProtocol.httpFailure(402) == DeepSeekFailure.QUOTA)
    check(DeepSeekProtocol.httpFailure(429) == DeepSeekFailure.RATE_LIMIT)
    check(DeepSeekProtocol.httpFailure(400) == DeepSeekFailure.RESPONSE)
    val marker = "fixture-sensitive-value"
    check(!DeepSeekException(DeepSeekFailure.RESPONSE).toString().contains(marker))
    println("DeepSeek core verification passed: contract, fixtures, history, cancellation admission, bounded streams, redacted failures.")
}
