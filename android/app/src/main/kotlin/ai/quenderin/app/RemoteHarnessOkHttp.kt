package ai.quenderin.app

import ai.quenderin.core.*
import java.io.ByteArrayOutputStream
import java.net.Proxy
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okio.BufferedSink
import okio.ByteString

/** Dedicated native Remote client. The sole interceptor prevents OkHttp's Retry-After:0 replay. */
internal fun remoteHarnessHTTPClient() = OkHttpClient.Builder()
    .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
    .authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
    .cookieJar(CookieJar.NO_COOKIES).cache(null).proxy(Proxy.NO_PROXY)
    .protocols(listOf(Protocol.HTTP_1_1)).addNetworkInterceptor(DeepSeekNoRetryGuard)
    .callTimeout(15, TimeUnit.SECONDS).connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(15, TimeUnit.SECONDS).writeTimeout(10, TimeUnit.SECONDS).build()

class RemoteHarnessOkHttpAPI internal constructor(private val calls: (Request) -> Call) : RemoteHarnessClientAPI {
    constructor() : this(run { val client = remoteHarnessHTTPClient(); { request: Request -> client.newCall(request) } })
    override fun login(origin: String, email: String, password: CharArray): RemoteHarnessClientLogin {
        val result = request(origin, "/api/v1/auth/login", "POST", RemoteHarnessJSON.obj(
            "email" to RemoteHarnessJSON.str(email), "password" to RemoteHarnessJSON.str(password.concatToString())))
        return RemoteHarnessClientLogin(result.string("token"), result.number("expiresAt"))
    }
    override fun register(record: RemoteHarnessClientCredentials, accountToken: String, publicIdentity: String) = pair(request(
        record.origin, "/api/v1/devices/register", "POST", RemoteHarnessJSON.obj("v" to RemoteHarnessJSON.num(1),
            "device" to RemoteHarnessJSON.obj("deviceId" to RemoteHarnessJSON.str(record.deviceID), "name" to RemoteHarnessJSON.str("Quenderin Android"),
                "role" to RemoteHarnessJSON.str("client"), "platform" to RemoteHarnessJSON.str("android"),
                "identityKey" to RemoteHarnessJSON.str(publicIdentity), "clientVersion" to RemoteHarnessJSON.str("quenderin-native/1"))), accountToken))
    override fun refresh(record: RemoteHarnessClientCredentials) = pair(request(record.origin, "/api/v1/auth/refresh", "POST",
        RemoteHarnessJSON.obj("deviceId" to RemoteHarnessJSON.str(record.deviceID), "refreshToken" to RemoteHarnessJSON.str(record.refreshToken!!))))
    override fun hosts(record: RemoteHarnessClientCredentials): List<RemoteHarnessClientHost> {
        val result = request(record.origin, "/api/v1/devices", token = record.accessToken)
        val items = result["items"] as? RemoteHarnessJSON.ArrayValue ?: protocolFailure()
        if (items.values.size > 256 || result["nextCursor"] !== RemoteHarnessJSON.NullValue) protocolFailure()
        return items.values.map { item -> host(item.objectValue(), full = false) }
    }
    override fun host(record: RemoteHarnessClientCredentials, summary: RemoteHarnessClientHost): RemoteHarnessClientHost {
        if (!Regex("^[A-Za-z0-9_-]{1,128}$").matches(summary.deviceID)) protocolFailure()
        val descriptor = host(request(record.origin, "/api/v1/devices/${summary.deviceID}", token = record.accessToken), full = true)
        val presence = request(record.origin, "/api/v1/devices/${summary.deviceID}/presence", token = record.accessToken)
        if (descriptor.deviceID != summary.deviceID || descriptor.membershipID != summary.membershipID ||
            presence.string("deviceId") != descriptor.deviceID) protocolFailure()
        return RemoteHarnessClientHost(descriptor.deviceID, descriptor.name, descriptor.membershipID, presence.boolean("online"),
            descriptor.publicKey, descriptor.fingerprint)
    }
    override fun revoke(record: RemoteHarnessClientCredentials) {
        if (request(record.origin, "/api/v1/devices/self", "DELETE", token = record.accessToken).string("status") != "revoked") protocolFailure()
    }
    private fun host(p: Map<String, RemoteHarnessJSON>, full: Boolean): RemoteHarnessClientHost {
        if (p.string("role") != "host") protocolFailure()
        val encoded = if (full) p.string("identityKey") else null
        val key = encoded?.let {
            if (!Regex("^[A-Za-z0-9_-]{43}$").matches(it)) protocolFailure()
            val bytes = try { Base64.getUrlDecoder().decode(it) } catch (_: Exception) { protocolFailure() }
            if (bytes.size != 32 || Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) != it) protocolFailure()
            bytes
        }
        p.number("lastSeenAt")
        return RemoteHarnessClientHost(p.string("deviceId"), p.string("name"), p.string("membershipId"), p.boolean("online"),
            key, key?.let(RemoteHarnessClientRecords::fingerprint))
    }
    private fun pair(p: Map<String, RemoteHarnessJSON>) = RemoteHarnessClientTokenPair(p.string("accessToken"), p.number("accessTokenExpiresAt"),
        p.string("refreshToken"), p.number("refreshTokenExpiresAt"))
    private fun request(origin: String, path: String, method: String = "GET", body: RemoteHarnessJSON? = null,
                        token: String? = null): Map<String, RemoteHarnessJSON> {
        if (!canonicalRemoteOrigin(origin) || !path.startsWith("/api/v1/")) protocolFailure()
        val builder = Request.Builder().url(origin + path).header("Accept", "application/json").header("Accept-Encoding", "identity")
        if (token != null) builder.header("Authorization", "Bearer $token")
        val data = body?.let { RemoteHarnessJSON.write(it).toByteArray(Charsets.UTF_8) }
        if (data != null && data.size > 16_384) protocolFailure()
        val request = builder.method(method, data?.let { bytes -> object : RequestBody() {
            override fun contentType() = "application/json; charset=utf-8".toMediaType()
            override fun contentLength() = bytes.size.toLong()
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
        } }).build()
        val call = calls(request)
        return try { call.execute().use { response ->
            if (response.request.url != request.url || response.request.url.scheme != "https") protocolFailure()
            if (!response.isSuccessful) throw RemoteHarnessException(if (response.code in setOf(401, 403)) "client-auth" else "client-connection")
            val responseBody = response.body ?: protocolFailure()
            if (responseBody.contentType()?.type != "application" || responseBody.contentType()?.subtype != "json" || responseBody.contentLength() > 65_536)
                protocolFailure()
            val out = ByteArrayOutputStream(); val buffer = ByteArray(4_096)
            responseBody.byteStream().use { input -> while (true) {
                val count = input.read(buffer); if (count < 0) break
                if (out.size() > 65_536 - count) protocolFailure(); out.write(buffer, 0, count)
            } }
            RemoteHarnessJSON.parse(out.toByteArray()).objectValue()
        } } catch (e: RemoteHarnessException) { throw e }
        catch (_: Exception) { throw RemoteHarnessException("client-connection") }
        finally { data?.fill(0); call.cancel() }
    }
}

/** All socket callbacks enter one bounded mailbox and then the client's enforced owner thread.
 * OkHttp's encrypted wire queue is independently bounded and has a finite drain deadline. */
class RemoteHarnessOkHttpSockets internal constructor(
    private val dispatch: (() -> Unit) -> Unit, private val now: () -> Long,
    private val open: (Request, WebSocketListener) -> WebSocket,
) : RemoteHarnessClientSocketFactory {
    constructor(dispatch: (() -> Unit) -> Unit, now: () -> Long) : this(dispatch, now,
        run { val client = remoteHarnessHTTPClient().newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build()
            val factory: (Request, WebSocketListener) -> WebSocket = { request, listener -> client.newWebSocket(request, listener) }
            factory })
    override fun connect(origin: String, listener: RemoteHarnessClientSocketListener): RemoteHarnessClientSocket {
        if (!canonicalRemoteOrigin(origin)) protocolFailure()
        val request = Request.Builder().url(origin + "/ws/v1/connect").build()
        return Connection(request, listener)
    }
    private inner class Connection(private val request: Request, private val listener: RemoteHarnessClientSocketListener) : RemoteHarnessClientSocket {
        private val queuedBytes = AtomicLong(); private val queuedMessages = AtomicInteger()
        private val ended = AtomicBoolean(false)
        private var reservedMessages = 0
        private var sendDeadline = 0L
        private val ws: WebSocket = open(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = deliver(0) {
                if (response.request.url != request.url || response.code != 101) fail() else listener.opened()
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (text.length > 1_048_576) { fail(); return }
                val bytes = text.toByteArray(Charsets.UTF_8)
                if (bytes.size > 1_048_576) { fail(); return }
                deliver(bytes.size) { listener.received(bytes) }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { fail() }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); fail() }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { fail() }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { response?.close(); fail() }
        })
        private fun deliver(size: Int, block: () -> Unit) {
            if (ended.get()) return
            val count = queuedMessages.incrementAndGet(); val bytes = queuedBytes.addAndGet(size.toLong())
            if (count > 256 || bytes > 8_388_608) {
                queuedMessages.decrementAndGet(); queuedBytes.addAndGet(-size.toLong()); fail(); return
            }
            dispatch {
                queuedMessages.decrementAndGet(); queuedBytes.addAndGet(-size.toLong())
                if (!ended.get()) block()
            }
        }
        private fun fail() {
            if (!ended.compareAndSet(false, true)) return
            dispatch { ws.cancel(); listener.closed() }
        }
        override fun send(bytes: ByteArray) {
            if (ended.get() || bytes.size > 1_048_576) throw RemoteHarnessException("client-connection")
            val queue = ws.queueSize()
            if (queue == 0L) { reservedMessages = 0; sendDeadline = 0 }
            if (reservedMessages >= 256 || queue > 8_388_608 - bytes.size) { close(); throw RemoteHarnessException("client-bounds") }
            if (sendDeadline == 0L) sendDeadline = now() + 10_000
            reservedMessages++
            if (!ws.send(bytes.toString(Charsets.UTF_8))) { close(); throw RemoteHarnessException("client-connection") }
        }
        override fun checkDeadline(now: Long) {
            if (ws.queueSize() == 0L) { sendDeadline = 0; reservedMessages = 0 }
            else if (sendDeadline != 0L && now >= sendDeadline) { close(); throw RemoteHarnessException("client-deadline") }
        }
        override fun close() { ended.set(true); ws.cancel() }
    }
}

private fun protocolFailure(): Nothing = throw RemoteHarnessException("client-protocol")
private fun canonicalRemoteOrigin(origin: String) = try { origin == ConnectionOrigins.canonicalize(origin) } catch (_: Exception) { false }
private fun Map<String, RemoteHarnessJSON>.string(name: String) = get(name)?.stringValue() ?: protocolFailure()
private fun Map<String, RemoteHarnessJSON>.number(name: String) = get(name)?.integerValue() ?: protocolFailure()
private fun Map<String, RemoteHarnessJSON>.boolean(name: String) = get(name)?.booleanValue() ?: protocolFailure()
