package ai.quenderin.app

import ai.quenderin.core.DeepSeekCatalog
import ai.quenderin.core.DeepSeekCancellation
import ai.quenderin.core.DeepSeekCredentialVault
import ai.quenderin.core.DeepSeekException
import ai.quenderin.core.DeepSeekFailure
import ai.quenderin.core.DeepSeekProtocol
import ai.quenderin.core.DeepSeekReply
import ai.quenderin.core.DeepSeekStreamParser
import ai.quenderin.core.DeepSeekTransport
import ai.quenderin.core.ProviderEvent
import ai.quenderin.core.ProviderRequest
import java.io.ByteArrayOutputStream
import java.io.InterruptedIOException
import java.net.Proxy
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Interceptor
import okhttp3.Protocol
import okio.BufferedSink

/** Dedicated fixed-origin client. It cannot inherit an app interceptor, cookie, auth retry or cache.
 * Each user action creates one call; redirect responses and all non-2xx responses are closed unread. */
class DeepSeekOkHttpTransport internal constructor(private val vault: DeepSeekCredentialVault,
    private val newCall: (Request, Long) -> Call) : DeepSeekTransport {
    constructor(vault: DeepSeekCredentialVault) : this(vault, { request, timeout ->
        client.newBuilder().callTimeout(timeout, TimeUnit.MILLISECONDS).build().newCall(request)
    })
    private val active = AtomicReference<Call?>()
    override fun cancel() { active.get()?.cancel() }

    override fun models(reference: String, cancellation: DeepSeekCancellation): List<String> = execute(reference, "/models", null, cancellation) { response ->
        val body = response.body ?: throw DeepSeekException(DeepSeekFailure.RESPONSE)
        if (body.contentType()?.type != "application" || body.contentType()?.subtype != "json")
            throw DeepSeekException(DeepSeekFailure.RESPONSE)
        val bytes = ByteArrayOutputStream()
        body.byteStream().use { stream ->
            val buffer = ByteArray(8_192)
            while (true) {
                val count = stream.read(buffer); if (count < 0) break
                if (bytes.size().toLong() + count > DeepSeekCatalog.MAX_TEXT_BYTES) throw DeepSeekException(DeepSeekFailure.LIMIT)
                bytes.write(buffer, 0, count)
            }
        }
        val source = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        DeepSeekProtocol.availableModels(source)
    }

    override fun stream(reference: String, request: ProviderRequest, cancellation: DeepSeekCancellation, onEvent: (ProviderEvent) -> Unit): DeepSeekReply {
        val body = DeepSeekProtocol.requestBody(request)
        val remaining = request.limits.deadlineEpochMs - System.currentTimeMillis()
        if (remaining !in 1..DeepSeekCatalog.TIMEOUT_MS) throw DeepSeekException(DeepSeekFailure.TIMEOUT)
        return execute(reference, "/chat/completions", body, cancellation, remaining) { response ->
            val responseBody = response.body ?: throw DeepSeekException(DeepSeekFailure.RESPONSE)
            if (responseBody.contentType()?.type != "text" || responseBody.contentType()?.subtype != "event-stream")
                throw DeepSeekException(DeepSeekFailure.RESPONSE)
            val parser = DeepSeekStreamParser("assistant-${request.requestID.removePrefix("request-")}", request.limits.maxToolCalls, onEvent)
            responseBody.byteStream().use { stream ->
                val buffer = ByteArray(8_192)
                while (true) {
                    if (System.currentTimeMillis() >= request.limits.deadlineEpochMs) throw DeepSeekException(DeepSeekFailure.TIMEOUT)
                    val count = stream.read(buffer); if (count < 0) break
                    cancellation.check(); parser.feed(buffer, count)
                }
            }
            parser.end()
        }
    }

    private fun <T> execute(reference: String, path: String, body: String?, cancellation: DeepSeekCancellation, timeoutMs: Long = DeepSeekCatalog.TIMEOUT_MS,
                            action: (okhttp3.Response) -> T): T {
        cancellation.check()
        if (path !in setOf("/models", "/chat/completions")) throw DeepSeekException(DeepSeekFailure.RESPONSE)
        val request = vault.use(reference) { key ->
            Request.Builder().url(DeepSeekCatalog.ORIGIN + path).header("Authorization", "Bearer ${key.concatToString()}")
                .header("Accept", if (body == null) "application/json" else "text/event-stream")
                .header("Accept-Encoding", "identity").apply {
                    if (body != null) post(object : RequestBody() {
                        private val bytes = body.toByteArray(Charsets.UTF_8)
                        override fun contentType() = "application/json; charset=utf-8".toMediaType()
                        override fun contentLength() = bytes.size.toLong()
                        // OkHttp also considers HTTP503/421 follow-ups. Marking paid requests one-shot
                        // blocks those replays in its retry interceptor, beyond connection retries.
                        override fun isOneShot() = true
                        override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
                    })
                }.build()
        }
        val call = newCall(request, timeoutMs)
        cancellation.register { call.cancel() }
        if (!active.compareAndSet(null, call)) {
            call.cancel(); cancellation.release(); throw DeepSeekException(DeepSeekFailure.BUSY)
        }
        return try {
            cancellation.check()
            call.execute().use { response ->
                if (response.request.url.scheme != "https" || response.request.url.host != "api.deepseek.com" ||
                    response.request.url.port != 443 || response.request.url.encodedPath != path)
                    throw DeepSeekException(DeepSeekFailure.RESPONSE)
                if (!response.isSuccessful) throw DeepSeekException(DeepSeekProtocol.httpFailure(response.code))
                val length = response.body?.contentLength() ?: -1
                if (length > DeepSeekCatalog.MAX_BYTES) throw DeepSeekException(DeepSeekFailure.LIMIT)
                action(response)
            }
        } catch (e: DeepSeekException) { throw e }
        catch (_: InterruptedIOException) { throw DeepSeekException(if (call.isCanceled()) DeepSeekFailure.CANCELLED else DeepSeekFailure.TIMEOUT) }
        catch (_: Exception) { throw DeepSeekException(if (call.isCanceled()) DeepSeekFailure.CANCELLED else DeepSeekFailure.CONNECTION) }
        finally { call.cancel(); active.compareAndSet(call, null); cancellation.release() }
    }

    companion object {
        // The single audited network guard only prevents OkHttp's status-driven 503 follow-up.
        // No application interceptors, logging, inherited clients, caches or credential automation.
        private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .cookieJar(CookieJar.NO_COOKIES).cache(null).proxy(Proxy.NO_PROXY)
            .protocols(listOf(Protocol.HTTP_1_1)).addNetworkInterceptor(DeepSeekNoRetryGuard)
            .callTimeout(120, TimeUnit.SECONDS).connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS).writeTimeout(30, TimeUnit.SECONDS).build()
    }
}

/** OkHttp4.12 retries Retry-After:0 HTTP503 even when retryOnConnectionFailure=false.
 * This fixed guard preserves status/body and changes only the internal retry hint. HTTP/1.1 also
 * prevents HTTP421 connection-coalescing follow-ups. It never reads or logs credentials or bodies. */
internal object DeepSeekNoRetryGuard : Interceptor {
    override fun intercept(chain: Interceptor.Chain): okhttp3.Response = blockFollowUp(chain.proceed(chain.request()))
    fun blockFollowUp(response: okhttp3.Response): okhttp3.Response = if (response.code == 503)
        response.newBuilder().header("Retry-After", Int.MAX_VALUE.toString()).build() else response
}
