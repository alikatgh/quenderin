package ai.quenderin.app.contentreport

import okhttp3.Authenticator
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Fill only with the independently verified versioned Apps Script /exec deployment. */
object ContentReportEndpoint {
    val url: String? = "https://script.google.com/macros/s/AKfycbwycXiGmhRpehG-SUnOnRCKBoosnaxpBEtpGerldMZyYHFF_X5wWfCs6Z_oYjPjEa7ftw/exec"
}

data class ReportHttpRequest(val url: HttpUrl, val body: String?, val remainingMillis: Long)
data class ReportHttpResponse(val status: Int, val location: String? = null, val body: String = "")

/** Injectable boundary used by offline fixtures; no test endpoint or production fallback exists. */
fun interface ReportExchange { fun execute(request: ReportHttpRequest): ReportHttpResponse }

class ContentReportTransport(
    private val endpoint: String? = ContentReportEndpoint.url,
    private val exchange: ReportExchange = BoundedReportExchange(),
    private val nanoTime: () -> Long = System::nanoTime,
) {
    fun send(report: PreparedReport): ReportResult {
        val start = endpoint?.toHttpUrlOrNull()?.takeIf(::validEndpoint) ?: return ReportResult.Unavailable
        val deadline = nanoTime() + TimeUnit.SECONDS.toNanos(20)
        var url = start
        var body: String? = report.json
        var redirects = 0
        return try {
            while (true) {
                val remaining = TimeUnit.NANOSECONDS.toMillis(deadline - nanoTime())
                if (remaining <= 0) return ReportResult.Unconfirmed
                val response = exchange.execute(ReportHttpRequest(url, body, remaining))
                if (nanoTime() >= deadline) return ReportResult.Unconfirmed
                if (response.status == 302 || response.status == 303) {
                    if (++redirects > 2) return ReportResult.Unconfirmed
                    val next = response.location?.toHttpUrlOrNull()?.takeIf(::validReceiptUrl)
                        ?: return ReportResult.Unconfirmed
                    url = next
                    body = null // ContentService redirect is GET only, never a replayed POST.
                    continue
                }
                if (response.status != 200 || response.body.toByteArray(Charsets.UTF_8).size > MAX_RESPONSE_BYTES)
                    return ReportResult.Unconfirmed
                return ContentReportProtocol.receipt(response.body, report.reportId)
            }
            @Suppress("UNREACHABLE_CODE") ReportResult.Unconfirmed
        } catch (_: IOException) { ReportResult.Unconfirmed }
          catch (_: IllegalArgumentException) { ReportResult.Unconfirmed }
    }

    companion object {
        const val MAX_RESPONSE_BYTES = 8192
        private fun cleanHttps(url: HttpUrl): Boolean = url.scheme == "https" && url.port == 443 &&
            url.username.isEmpty() && url.password.isEmpty() && url.fragment == null
        fun validEndpoint(url: HttpUrl): Boolean = cleanHttps(url) && url.host == "script.google.com" &&
            Regex("/macros/s/[A-Za-z0-9_-]+/exec").matches(url.encodedPath) && url.encodedQuery == null
        fun validReceiptUrl(url: HttpUrl): Boolean = cleanHttps(url) && url.host == "script.googleusercontent.com"
    }
}

private class BoundedReportExchange : ReportExchange {
    private val client = OkHttpClient.Builder()
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
        .protocols(listOf(Protocol.HTTP_1_1)) // No HTTP/2 coalescing and its automatic 421 replay.
        .addNetworkInterceptor { chain ->
            val response = chain.proceed(chain.request())
            // OkHttp can retry a 503/Retry-After:0 even with connection retries disabled.
            // Preserve the rejection while making that internal follow-up ineligible.
            if (response.code == 503) response.newBuilder().header("Retry-After", "86400").build() else response
        }
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(8, TimeUnit.SECONDS).writeTimeout(8, TimeUnit.SECONDS)
        .build()

    override fun execute(request: ReportHttpRequest): ReportHttpResponse {
        val builder = Request.Builder().url(request.url).header("Accept", "application/json")
        request.body?.let { builder.post(it.toRequestBody("application/json; charset=utf-8".toMediaType())) }
            ?: builder.get()
        val call = client.newCall(builder.build())
        call.timeout().timeout(request.remainingMillis, TimeUnit.MILLISECONDS)
        return call.execute().use { response ->
            val status = response.code
            if (status != 200) return@use ReportHttpResponse(status, response.header("Location"))
            val input = response.body?.byteStream() ?: throw IOException("Missing receipt")
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(1024)
            while (true) {
                val count = input.read(buffer)
                if (count == -1) break
                if (bytes.size() + count > ContentReportTransport.MAX_RESPONSE_BYTES) throw IOException("Receipt too large")
                bytes.write(buffer, 0, count)
            }
            // Decode strictly: replacement characters must not make malformed UTF-8 a valid receipt.
            val decoder = Charsets.UTF_8.newDecoder()
            val text = decoder.decode(java.nio.ByteBuffer.wrap(bytes.toByteArray())).toString()
            ReportHttpResponse(status, body = text)
        }
    }
}
