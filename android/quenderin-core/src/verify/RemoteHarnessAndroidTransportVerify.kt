package ai.quenderin.app

import ai.quenderin.core.*
import java.io.IOException
import java.util.Base64
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.ByteString
import okio.Timeout

private class RemoteFixtureCall(val outbound: Request, val action: (Request) -> Response) : Call {
    var count = 0; var cancelled = false
    override fun request() = outbound
    override fun execute(): Response { count++; return action(outbound) }
    override fun enqueue(responseCallback: Callback) = error("unexpected async fixture")
    override fun cancel() { cancelled = true }
    override fun isExecuted() = count > 0
    override fun isCanceled() = cancelled
    override fun timeout() = Timeout()
    override fun clone() = RemoteFixtureCall(outbound, action)
}
private fun reply(request: Request, source: String, code: Int = 200) = Response.Builder().request(request).protocol(Protocol.HTTP_1_1)
    .code(code).message("fixture").body(source.toResponseBody("application/json".toMediaType())).build()
private class RemoteFixtureWebSocket(val outbound: Request) : WebSocket {
    var bytes = 0L; var cancelled = false; var admit = true
    val sent = mutableListOf<String>()
    override fun request() = outbound
    override fun queueSize() = bytes
    override fun send(text: String): Boolean { sent.add(text); return admit }
    override fun send(bytes: ByteString) = error("binary send forbidden")
    override fun close(code: Int, reason: String?) = true
    override fun cancel() { cancelled = true }
}
fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    fun fails(action: () -> Unit) {
        try { action(); error("expected fixed local failure") }
        catch (e: RemoteHarnessException) { verify(!e.toString().contains("fixture-private")) }
    }
    val actual = remoteHarnessHTTPClient()
    verify(!actual.followRedirects && !actual.followSslRedirects && !actual.retryOnConnectionFailure)
    verify(actual.authenticator === Authenticator.NONE && actual.proxyAuthenticator === Authenticator.NONE && actual.cookieJar === CookieJar.NO_COOKIES)
    verify(actual.cache == null && actual.proxy == java.net.Proxy.NO_PROXY && actual.interceptors.isEmpty())
    verify(actual.protocols == listOf(Protocol.HTTP_1_1) && actual.callTimeoutMillis == 15_000)
    verify(actual.networkInterceptors.single() === DeepSeekNoRetryGuard)
    val calls = mutableListOf<RemoteFixtureCall>(); var nextCode = 200
    val key = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 8 })
    val api = RemoteHarnessOkHttpAPI { request ->
        RemoteFixtureCall(request) { r ->
            verify(r.url.scheme == "https" && r.url.host == "relay.example.org" && r.url.query == null && r.header("Cookie") == null)
            val path = r.url.encodedPath
            if (r.method == "POST") verify(r.body?.isOneShot() == true)
            val source = when (path) {
                "/api/v1/auth/login" -> {
                    val data = Buffer(); r.body!!.writeTo(data)
                    val p = RemoteHarnessJSON.parse(data.readUtf8()).objectValue()
                    verify(p.getValue("email").stringValue() == "fixture@example.org" && p.getValue("password").stringValue() == "fixture-only")
                    verify(r.header("Authorization") == null)
                    "{\"token\":\"account_fixture\",\"expiresAt\":1800028800000,\"account\":\"fixture@example.org\",\"profile\":{},\"isAdmin\":false}"
                }
                "/api/v1/devices/register" -> {
                    verify(r.header("Authorization") == "Bearer account_fixture")
                    val data = Buffer(); r.body!!.writeTo(data); val p = RemoteHarnessJSON.parse(data.readUtf8()).objectValue()
                    verify(p.getValue("v").integerValue() == 1L && p.getValue("device").objectValue().getValue("role").stringValue() == "client")
                    "{\"accessToken\":\"access_fixture\",\"refreshToken\":\"refresh_fixture\",\"accessTokenExpiresAt\":1800003600000,\"refreshTokenExpiresAt\":1802592000000}"
                }
                "/api/v1/auth/refresh" -> {
                    verify(r.header("Authorization") == null)
                    "{\"accessToken\":\"access_rotated\",\"refreshToken\":\"refresh_rotated\",\"accessTokenExpiresAt\":1800007200000,\"refreshTokenExpiresAt\":1802592000000}"
                }
                "/api/v1/devices" -> "{\"items\":[{\"deviceId\":\"host-a\",\"name\":\"Laptop\",\"role\":\"host\",\"membershipId\":\"member-fixture\",\"online\":true,\"lastSeenAt\":1800000000000}],\"nextCursor\":null}"
                "/api/v1/devices/host-a" -> "{\"deviceId\":\"host-a\",\"name\":\"Laptop\",\"role\":\"host\",\"membershipId\":\"member-fixture\",\"identityKey\":\"$key\",\"online\":true,\"lastSeenAt\":1800000000000}"
                "/api/v1/devices/host-a/presence" -> "{\"deviceId\":\"host-a\",\"online\":true,\"lastSeenAt\":1800000000000}"
                "/api/v1/devices/self" -> "{\"status\":\"revoked\"}"
                else -> error("unexpected fixture route")
            }
            reply(r, source, nextCode)
        }.also { calls.add(it) }
    }
    val reserved = RemoteHarnessClientCredentials("https://relay.example.org", "client-fixture", ByteArray(32))
    val login = api.login(reserved.origin, "fixture@example.org", "fixture-only".toCharArray())
    verify(login.expiresAt == 1_800_028_800_000L)
    val pair = api.register(reserved, login.token, key)
    val enrolled = reserved.replacing(RemoteHarnessCredentialPhase.READY, pair)
    val host = api.host(enrolled, api.hosts(enrolled).single())
    verify(host.publicKey!!.contentEquals(ByteArray(32) { 8 }) && host.fingerprint?.length == 64)
    verify(api.refresh(enrolled).refreshExpiresAt == pair.refreshExpiresAt)
    api.revoke(enrolled)
    verify(calls.all { it.count == 1 && it.cancelled })
    nextCode = 503; fails { api.login(reserved.origin, "fixture@example.org", "fixture-only".toCharArray()) }
    verify(calls.last().count == 1)
    fails { api.login("http://relay.example.org", "fixture@example.org", "fixture-only".toCharArray()) }

    // Invoke OkHttp4.12's real status-followup decision against the actual production builder.
    val retryType = Class.forName("okhttp3.internal.http.RetryAndFollowUpInterceptor")
    val retry = retryType.getConstructor(OkHttpClient::class.java).newInstance(actual)
    val follow = retryType.getDeclaredMethod("followUpRequest", Response::class.java,
        Class.forName("okhttp3.internal.connection.Exchange")).apply { isAccessible = true }
    val get = Request.Builder().url("https://relay.example.org/api/v1/devices").build()
    val status = reply(get, "{}", 503).newBuilder().header("Retry-After", "0").build()
    verify(follow.invoke(retry, status, null) is Request)
    verify(follow.invoke(retry, DeepSeekNoRetryGuard.blockFollowUp(status), null) == null)

    val mailbox = java.util.ArrayDeque<() -> Unit>(); var now = 1_000L
    var wsListener: WebSocketListener? = null; var ws: RemoteFixtureWebSocket? = null
    var opens = 0; var closed = 0; var messages = 0
    val socketFactory = RemoteHarnessOkHttpSockets({ mailbox.add(it) }, { now }) { request, listener ->
        verify(request.url.toString() == "https://relay.example.org/ws/v1/connect" && request.url.query == null && request.header("Authorization") == null)
        wsListener = listener; RemoteFixtureWebSocket(request).also { ws = it }
    }
    fun pump() { while (mailbox.isNotEmpty()) mailbox.removeFirst().invoke() }
    fun listener() = object : RemoteHarnessClientSocketListener {
        override fun opened() { opens++ }
        override fun received(bytes: ByteArray) { messages++ }
        override fun closed() { closed++ }
    }
    val socket = socketFactory.connect(reserved.origin, listener())
    wsListener!!.onOpen(ws!!, reply(ws!!.request(), "", 101)); verify(opens == 0); pump(); verify(opens == 1)
    wsListener!!.onMessage(ws!!, "{}"); verify(messages == 0); pump(); verify(messages == 1)
    socket.send("{}".toByteArray()); verify(ws!!.sent.single() == "{}")
    ws!!.bytes = 8_388_608; fails { socket.send("{}".toByteArray()) }; verify(ws!!.cancelled)
    val deadline = socketFactory.connect(reserved.origin, listener())
    ws!!.bytes = 1; deadline.send("{}".toByteArray()); now += 10_001
    fails { deadline.checkDeadline(now) }; verify(ws!!.cancelled)
    val bounded = socketFactory.connect(reserved.origin, listener())
    repeat(257) { wsListener!!.onMessage(ws!!, "{}") }; pump(); verify(ws!!.cancelled && closed == 1)
    bounded.close()
    val binary = socketFactory.connect(reserved.origin, listener())
    wsListener!!.onMessage(ws!!, ByteString.EMPTY); pump(); verify(ws!!.cancelled && closed == 2); binary.close()
    println("Remote Harness Android OkHttp: $checks checks passed (synthetic HTTP/socket only).")
}
