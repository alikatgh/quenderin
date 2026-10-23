package ai.quenderin.app

import ai.quenderin.core.*
import java.io.IOException
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.Timeout

private class FixtureVault : DeepSeekCredentialVault {
    var saved = false
    var wiped: CharArray? = null
    val references = mutableSetOf("qcred:fixture")
    val removed = mutableListOf<String>()
    private var counter = 0
    override fun save(key: CharArray): String {
        saved = true
        return "qcred:saved-${++counter}".also { references.add(it) }
    }
    override fun <T> use(reference: String, action: (CharArray) -> T): T {
        if (reference !in references) throw DeepSeekException(DeepSeekFailure.CREDENTIAL)
        val chars = "fixture-key-not-a-credential".toCharArray()
        return try { action(chars) } finally { chars.fill('\u0000'); wiped = chars }
    }
    override fun remove(reference: String) { saved = false; references.remove(reference); removed.add(reference) }
    override fun removeAll() { saved = false; references.clear() }
}

private class FixtureCall(private val outbound: Request, private val respond: (FixtureCall) -> Response) : Call {
    var executions = 0
    @Volatile private var cancelled = false
    override fun request() = outbound
    override fun execute(): Response { executions++; if (cancelled) throw IOException("fixture-private-body"); return respond(this) }
    override fun enqueue(responseCallback: Callback) = error("Async calls are forbidden in this fixture")
    override fun cancel() { cancelled = true }
    override fun isExecuted() = executions > 0
    override fun isCanceled() = cancelled
    override fun timeout() = Timeout()
    override fun clone(): Call = FixtureCall(outbound, respond)
}

private fun response(request: Request, code: Int = 200, body: ResponseBody = "{\"data\":[{\"id\":\"deepseek-flash\"}]}".toResponseBody("application/json".toMediaType())) =
    Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("fixture").body(body).build()

private fun failure(expected: DeepSeekFailure, action: () -> Unit) {
    try { action(); error("Expected failure: $expected") }
    catch (e: DeepSeekException) {
        check(e.failure == expected) { "Wrong fixed failure: ${e.failure}" }
        check(!e.toString().contains("fixture-private-body") && !e.message.orEmpty().contains("fixture-key"))
    }
}

private class FixturePersistence : DeepSeekPersistence {
    var profile: ConnectionProfile? = null
    val saved = linkedMapOf<String, String>()
    var failRead = false
    var failWrite = false
    var failProfileAfterMutation = false
    var afterFinalWrite: (() -> Unit)? = null
    override fun readProfile(): ConnectionProfile? { if (failRead) throw IOException("fixture-private-body"); return profile }
    override fun writeProfile(profile: ConnectionProfile?) {
        this.profile = profile
        if (failProfileAfterMutation) throw DeepSeekException(DeepSeekFailure.STORAGE)
    }
    override fun readConversations() = saved.values.map(DeepSeekConversation::decode)
    override fun writeConversation(conversation: DeepSeekConversation) {
        if (failWrite) throw IOException("fixture-private-body")
        saved[conversation.envelope.conversationID] = conversation.encode()
        if (!conversation.incomplete && conversation.envelope.messages.isNotEmpty()) afterFinalWrite?.invoke()
    }
}

private class FixtureTransport : DeepSeekTransport {
    var beforeAdmission: (() -> Unit)? = null
    var entered: (() -> Unit)? = null
    val executions = AtomicInteger()
    var modelsCalls = 0
    var streamCalls = 0
    var fail: DeepSeekFailure? = null
    override fun models(reference: String, cancellation: DeepSeekCancellation): List<String> {
        modelsCalls++; cancellation.check(); return listOf(DeepSeekCatalog.DEFAULT_MODEL)
    }
    override fun stream(reference: String, request: ProviderRequest, cancellation: DeepSeekCancellation,
                        onEvent: (ProviderEvent) -> Unit): DeepSeekReply {
        streamCalls++
        beforeAdmission?.invoke()
        cancellation.register { }
        cancellation.check(); executions.incrementAndGet(); entered?.invoke()
        fail?.let { throw DeepSeekException(it) }
        val id = "assistant-${request.requestID.removePrefix("request-")}"
        onEvent(ProviderEvent.Reasoning(id, "fixture reasoning"))
        onEvent(ProviderEvent.Text(id, "fixture answer"))
        cancellation.check()
        return DeepSeekReply("fixture answer", "fixture reasoning", emptyList(), DeepSeekUsage(4, 5), "stop")
    }
    override fun cancel() {}
}

private fun awaitState(controller: DeepSeekController, condition: (DeepSeekUiState) -> Boolean): DeepSeekUiState = runBlocking {
    withTimeout(5_000) { controller.state.first(condition) }
}

fun main(args: Array<String>) {
    // Inspect the actual production client, never a substitute builder.
    val field = DeepSeekOkHttpTransport::class.java.getDeclaredField("client").apply { isAccessible = true }
    val client = field.get(null) as OkHttpClient
    check(!client.followRedirects && !client.followSslRedirects && !client.retryOnConnectionFailure)
    check(client.authenticator === Authenticator.NONE && client.proxyAuthenticator === Authenticator.NONE)
    check(client.cookieJar === CookieJar.NO_COOKIES && client.cache == null)
    check(client.interceptors.isEmpty() && client.networkInterceptors.single() === DeepSeekNoRetryGuard)
    check(client.protocols == listOf(Protocol.HTTP_1_1))
    check(client.proxy == java.net.Proxy.NO_PROXY && client.callTimeoutMillis == 120_000)

    val vault = FixtureVault()
    var observed: Request? = null
    val transport = DeepSeekOkHttpTransport(vault) { request, timeout ->
        observed = request
        check(timeout in 1..120_000)
        FixtureCall(request) { response(request) }
    }
    check(transport.models("qcred:fixture", DeepSeekCancellation()) == listOf(DeepSeekCatalog.DEFAULT_MODEL))
    check(observed!!.url.toString() == "https://api.deepseek.com/models" && observed!!.method == "GET")
    check(observed!!.header("Authorization") == "Bearer fixture-key-not-a-credential")
    check(observed!!.header("Cookie") == null && observed!!.header("Accept-Encoding") == "identity")
    check(vault.wiped!!.all { it == '\u0000' })

    // Exercise the actual pinned OkHttp follow-up decision, including its surprising HTTP503 retry.
    val retryClass = Class.forName("okhttp3.internal.http.RetryAndFollowUpInterceptor")
    val retry = retryClass.getConstructor(OkHttpClient::class.java).newInstance(client)
    val followUp = retryClass.getDeclaredMethod("followUpRequest", Response::class.java,
        Class.forName("okhttp3.internal.connection.Exchange")).apply { isAccessible = true }
    val get503 = response(observed!!, 503).newBuilder().header("Retry-After", "0").build()
    check(followUp.invoke(retry, get503, null) is Request) // retryOnConnectionFailure=false alone is insufficient.
    check(followUp.invoke(retry, DeepSeekNoRetryGuard.blockFollowUp(get503), null) == null)

    val profile = DeepSeekCatalog.profile("qcred:fixture")
    val thread = DeepSeekConversation.new(profile, "transport-fixture", DeepSeekCatalog.selection())
    val request = thread.begin(profile, "fixture input", DeepSeekCatalog.selection(), System.currentTimeMillis(), "test")
    val sse = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer\"},\"finish_reason\":null}]}\n\n" +
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n"
    val streamTransport = DeepSeekOkHttpTransport(vault) { outbound, _ ->
        check(outbound.url.toString() == "https://api.deepseek.com/chat/completions" && outbound.method == "POST")
        check(outbound.body?.isOneShot() == true)
        val post503 = response(outbound, 503).newBuilder().header("Retry-After", "0").build()
        check(followUp.invoke(retry, DeepSeekNoRetryGuard.blockFollowUp(post503), null) == null)
        FixtureCall(outbound) { response(outbound, body = sse.toResponseBody("text/event-stream".toMediaType())) }
    }
    val result = streamTransport.stream("qcred:fixture", request, DeepSeekCancellation(), thread::event)
    check(result.text == "answer" && thread.partial == "answer")

    for ((code, expected) in listOf(301 to DeepSeekFailure.CONNECTION, 302 to DeepSeekFailure.CONNECTION,
        307 to DeepSeekFailure.CONNECTION, 308 to DeepSeekFailure.CONNECTION, 401 to DeepSeekFailure.CREDENTIAL,
        402 to DeepSeekFailure.QUOTA, 429 to DeepSeekFailure.RATE_LIMIT, 400 to DeepSeekFailure.RESPONSE)) {
        val fixture = DeepSeekOkHttpTransport(vault) { outbound, _ -> FixtureCall(outbound) { response(outbound, code,
            object : ResponseBody() {
                override fun contentType() = "text/plain".toMediaType()
                override fun contentLength() = 99L
                override fun source(): BufferedSource = error("Error bodies must never be read")
                override fun close() {}
            }) } }
        failure(expected) { fixture.models("qcred:fixture", DeepSeekCancellation()) }
    }
    val wrongOrigin = DeepSeekOkHttpTransport(vault) { outbound, _ -> FixtureCall(outbound) {
        response(outbound.newBuilder().url("https://example.invalid/models").build())
    } }
    failure(DeepSeekFailure.RESPONSE) { wrongOrigin.models("qcred:fixture", DeepSeekCancellation()) }
    val oversized = DeepSeekOkHttpTransport(vault) { outbound, _ -> FixtureCall(outbound) {
        response(outbound, body = object : ResponseBody() {
            override fun contentType() = "application/json".toMediaType()
            override fun contentLength() = DeepSeekCatalog.MAX_BYTES.toLong() + 1
            override fun source(): BufferedSource = error("Declared oversized bodies must never be read")
            override fun close() {}
        })
    } }
    failure(DeepSeekFailure.LIMIT) { oversized.models("qcred:fixture", DeepSeekCancellation()) }
    val actualOversized = DeepSeekOkHttpTransport(vault) { outbound, _ -> FixtureCall(outbound) {
        response(outbound, body = "x".repeat(DeepSeekCatalog.MAX_TEXT_BYTES + 1).toResponseBody("application/json".toMediaType()))
    } }
    failure(DeepSeekFailure.LIMIT) { actualOversized.models("qcred:fixture", DeepSeekCancellation()) }

    val cancelled = DeepSeekCancellation().apply { cancel() }
    val created = AtomicInteger()
    val neverCall = DeepSeekOkHttpTransport(vault) { outbound, _ -> created.incrementAndGet(); FixtureCall(outbound) { response(outbound) } }
    failure(DeepSeekFailure.CANCELLED) { neverCall.models("qcred:fixture", cancelled) }
    check(created.get() == 0)
    val factoryEntered = CountDownLatch(1)
    val allowRegistration = CountDownLatch(1)
    val cancelledInGap = DeepSeekCancellation()
    lateinit var gapCall: FixtureCall
    val gapTransport = DeepSeekOkHttpTransport(vault) { outbound, _ ->
        gapCall = FixtureCall(outbound) { response(outbound) }
        factoryEntered.countDown(); check(allowRegistration.await(3, TimeUnit.SECONDS)); gapCall
    }
    val worker = thread { failure(DeepSeekFailure.CANCELLED) { gapTransport.models("qcred:fixture", cancelledInGap) } }
    check(factoryEntered.await(3, TimeUnit.SECONDS)); cancelledInGap.cancel(); allowRegistration.countDown(); worker.join()
    check(gapCall.executions == 0 && gapCall.isCanceled())

    val store = FixturePersistence()
    val fake = FixtureTransport()
    val controller = DeepSeekController(vault, fake, store)
    awaitState(controller) { it.ready }
    val key = "fixture-key-not-a-credential".toCharArray()
    controller.connect(key)
    awaitState(controller) { it.connected && !it.busy }
    check(key.all { it == '\u0000' } && fake.modelsCalls == 1 && fake.streamCalls == 0)
    check(!NativeConnectionsCodec.encodeProfile(store.profile!!).contains("fixture-key"))
    controller.newConversation(false); check(controller.state.value.currentID == null)
    controller.newConversation(true)
    // Force Stop at the final-commit boundary before the sending coroutine reaches finally.
    // A completed exchange must never become interrupted because the UI still had a Stop action.
    store.afterFinalWrite = { controller.stop() }
    fake.entered = { check(store.saved.values.map(DeepSeekConversation::decode).single().incomplete) }
    controller.send("fixture input")
    val completed = awaitState(controller) { !it.busy && it.rows.size == 2 }
    check(completed.rows.last().text == "fixture answer" && completed.rows.last().reasoning == "fixture reasoning")
    check(completed.usage?.outputTokens == 5L)
    check(!completed.incomplete && !DeepSeekConversation.decode(store.saved.values.single()).incomplete)
    store.afterFinalWrite = null
    controller.close()
    val restored = DeepSeekController(vault, fake, store)
    check(awaitState(restored) { it.ready }.rows.size == 2)
    restored.close()

    val gapStore = FixturePersistence().apply { this.profile = profile }
    val gapFake = FixtureTransport()
    val admission = CountDownLatch(1)
    val releaseAdmission = CountDownLatch(1)
    gapFake.beforeAdmission = { admission.countDown(); check(releaseAdmission.await(3, TimeUnit.SECONDS)) }
    val gapController = DeepSeekController(vault, gapFake, gapStore)
    awaitState(gapController) { it.ready }; gapController.newConversation(true); gapController.send("fixture input")
    check(admission.await(3, TimeUnit.SECONDS)); gapController.stop()
    check(gapController.state.value.busy)
    gapController.send("must not enqueue")
    releaseAdmission.countDown()
    val stopped = awaitState(gapController) { !it.busy }
    check(gapFake.executions.get() == 0 && gapFake.streamCalls == 1 && stopped.incomplete)
    gapController.send("must not replay"); check(gapFake.streamCalls == 1)
    gapController.close()

    val failedStore = FixturePersistence().apply { failRead = true }
    val failedController = DeepSeekController(vault, FixtureTransport(), failedStore)
    val storageError = awaitState(failedController) { it.message != null }
    check(!storageError.ready && !storageError.connected)
    failedController.newConversation(true); check(failedStore.saved.isEmpty()); failedController.close()

    val writeStore = FixturePersistence().apply { this.profile = profile }
    val writeFake = FixtureTransport()
    val writeController = DeepSeekController(vault, writeFake, writeStore)
    awaitState(writeController) { it.ready }; writeController.newConversation(true); writeStore.failWrite = true
    writeController.send("must not dispatch")
    awaitState(writeController) { !it.busy }
    check(writeFake.streamCalls == 0); writeController.close()

    val uncertainVault = FixtureVault()
    val uncertainStore = FixturePersistence().apply { this.profile = profile; failProfileAfterMutation = true }
    val uncertainController = DeepSeekController(uncertainVault, FixtureTransport(), uncertainStore)
    awaitState(uncertainController) { it.ready }
    uncertainController.connect("fixture-new-key".toCharArray())
    val uncertainState = awaitState(uncertainController) { !it.busy && it.message == DeepSeekFailure.STORAGE.userMessage }
    check(!uncertainState.ready)
    uncertainController.newConversation(true); uncertainController.send("must not dispatch")
    check(uncertainStore.saved.isEmpty())
    val possiblyInstalledReference = uncertainStore.profile!!.credentialReference!!
    check(possiblyInstalledReference != profile.credentialReference)
    check(possiblyInstalledReference in uncertainVault.references && profile.credentialReference in uncertainVault.references)
    check(uncertainVault.removed.isEmpty())
    uncertainController.close()
    val uncertainRelaunch = DeepSeekController(uncertainVault, FixtureTransport(), uncertainStore)
    awaitState(uncertainRelaunch) { it.ready }
    uncertainVault.use(uncertainStore.profile!!.credentialReference!!) { check(it.isNotEmpty()) }
    uncertainRelaunch.close()

    // Guard the composition boundary: a cloud visit must retain existing local remember owners.
    val root = File(args.firstOrNull() ?: ".")
    val router = File(root, "android/app/src/main/kotlin/ai/quenderin/app/ui/OnboardingScreen.kt").readText()
    val cloudRoute = router.substringAfter("if (showDeepSeek) {").substringBefore("var showImagesBeforeChat")
    check("Dialog(" in cloudRoute && "SecureFlagPolicy.SecureOn" in cloudRoute && !Regex("\\breturn\\b").containsMatchIn(cloudRoute))
    val keyEntry = File(root, "android/app/src/main/kotlin/ai/quenderin/app/ui/DeepSeekScreen.kt").readText()
    check("IME_FLAG_NO_PERSONALIZED_LEARNING" in keyEntry && "isSaveEnabled = false" in keyEntry && "isSaveFromParentEnabled = false" in keyEntry)
    for (path in listOf("backup_rules.xml", "data_extraction_rules.xml")) {
        val xml = File(root, "android/app/src/main/res/xml/$path").readText()
        check("deepseek_credentials.xml" in xml && "deepseek_profile.xml" in xml)
    }
    println("DeepSeek Android host verification passed: production transport policy, fixed-origin requests, redaction, response bounds, cancellation races, setup, persistence and storage failures.")
}
