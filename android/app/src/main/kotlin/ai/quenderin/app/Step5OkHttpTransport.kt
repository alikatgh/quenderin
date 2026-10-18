package ai.quenderin.app

import ai.quenderin.core.Step5Response
import ai.quenderin.core.Step5Transport
import java.net.Proxy
import java.net.URI
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** App-owned connection policy, independent of process-global Java credentials/cookies/proxies. */
class Step5OkHttpTransport : Step5Transport {
    private val cancelled = AtomicBoolean(false)
    private val active = AtomicReference<Call?>()
    override fun cancel() { cancelled.set(true); active.get()?.cancel() }
    override fun open(url: URI, body: ByteArray?, timeoutMs: Int): Step5Response {
        if (cancelled.get()) throw CancellationException("Step 5 request cancelled.")
        require(timeoutMs in 1..180_000)
        val client = base.newBuilder().callTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS).writeTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS).build()
        val request = Request.Builder().url(url.toASCIIString()).header("Accept", "application/json").apply {
            if (body != null) post(body.toRequestBody("application/json; charset=utf-8".toMediaType()))
        }.build()
        val call = client.newCall(request)
        check(active.compareAndSet(null, call)) { "A Step 5 transport operation is already running." }
        if (cancelled.get()) { call.cancel(); active.compareAndSet(call, null); throw CancellationException("Step 5 request cancelled.") }
        try {
            val response = call.execute()
            val stream = response.body ?: run { response.close(); error("The Step 5 gateway returned no response body.") }
            return Step5Response(response.code, stream.contentLength(), stream.byteStream()) { response.close(); active.compareAndSet(call, null) }
        } catch (error: Exception) { call.cancel(); active.compareAndSet(call, null); throw error }
    }
    companion object {
        // Builders share this bounded connection pool and dispatcher, rather than leaking one per request.
        private val base = OkHttpClient.Builder().authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .cookieJar(CookieJar.NO_COOKIES).retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false)
            .proxy(Proxy.NO_PROXY).callTimeout(180, TimeUnit.SECONDS).connectTimeout(180, TimeUnit.SECONDS)
            .readTimeout(180, TimeUnit.SECONDS).writeTimeout(180, TimeUnit.SECONDS).build()
    }
}
