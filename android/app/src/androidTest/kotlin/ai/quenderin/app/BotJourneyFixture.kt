package ai.quenderin.app

import ai.quenderin.core.*
import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Test APK only. Protocol shapes reuse RemoteHarnessClientVerify; no network or native crypto.
 * All callbacks run through the real controller's owner executor, including reconnects. */
internal class BotJourneyFixture {
    private val now = 1_800_000_000_000L
    private val clock = object : RemoteHarnessClock {
        override fun epochMilliseconds() = now
        override fun monotonicMilliseconds() = 1_000L
    }
    private var credentialBytes: String? = null
    private var savedBytes: String? = null
    private var recoveryAllowed = false
    private var deviceID = ""
    private var identifier = 0
    val botReads = AtomicInteger()
    val prompts = AtomicInteger()
    val modelChanges = AtomicInteger()
    val lastFollowSession = AtomicReference<String?>(null)
    private val hostKey = ByteArray(32) { 8 }
    private val credentials = object : RemoteHarnessClientCredentialStore {
        override fun read() = credentialBytes?.let(RemoteHarnessClientRecords::credentials)
        override fun write(record: RemoteHarnessClientCredentials) { credentialBytes = RemoteHarnessClientRecords.credentials(record) }
    }
    private val state = object : RemoteHarnessClientStateStore {
        override fun read() = savedBytes?.let(RemoteHarnessClientRecords::state)
        override fun write(state: RemoteHarnessClientSavedState) { savedBytes = RemoteHarnessClientRecords.state(state) }
    }
    private val recovery = object : RemoteHarnessClientRecoveryIntentStore {
        override fun read() = recoveryAllowed
        override fun write(allowed: Boolean) { recoveryAllowed = allowed }
    }
    private val crypto = object : RemoteHarnessCryptoBackend {
        override val isAvailable = true
        override fun publicKey(privateSeed: ByteArray) = ByteArray(32) { 7 }
        override fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo) = object : RemoteHarnessSecureNoise {
            var complete = false; var sent = 0L; var received = 0L
            override fun initiate(emptyPayload: ByteArray) = byteArrayOf(1)
            override fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult {
                complete = true; return RemoteHarnessSecureHandshakeResult(true, byteArrayOf())
            }
            override fun counters() = RemoteHarnessSecureCounters(complete, sent, received)
            override fun encrypt(plaintext: ByteArray): ByteArray { sent++; return ByteArray(16) + plaintext }
            override fun decrypt(ciphertext: ByteArray): ByteArray { received++; return ciphertext.copyOfRange(16, ciphertext.size) }
            override fun shutdown() {}
        }
    }
    private val api = object : RemoteHarnessClientAPI {
        override fun login(origin: String, email: String, password: CharArray) = RemoteHarnessClientLogin("synthetic_account", now + 3_600_000)
        override fun register(record: RemoteHarnessClientCredentials, accountToken: String, publicIdentity: String): RemoteHarnessClientTokenPair {
            deviceID = record.deviceID
            return RemoteHarnessClientTokenPair("synthetic_access", now + 3_600_000, "synthetic_refresh", now + 86_400_000)
        }
        override fun refresh(record: RemoteHarnessClientCredentials): RemoteHarnessClientTokenPair = error("Unexpected token refresh")
        override fun hosts(record: RemoteHarnessClientCredentials) = listOf(RemoteHarnessClientHost("host-a", "Synthetic computer", "fixture-account", true))
        override fun host(record: RemoteHarnessClientCredentials, summary: RemoteHarnessClientHost) = RemoteHarnessClientHost(
            summary.deviceID, summary.name, summary.membershipID, true, hostKey, RemoteHarnessClientRecords.fingerprint(hostKey))
        override fun revoke(record: RemoteHarnessClientCredentials) = error("Unexpected revoke")
    }
    fun client(schedule: (() -> Unit) -> Unit): RemoteHarnessClient {
        val sockets = object : RemoteHarnessClientSocketFactory {
            override fun connect(origin: String, listener: RemoteHarnessClientSocketListener): RemoteHarnessClientSocket =
                Socket(listener, schedule, "fixture-connection-${++identifier}").also { schedule { listener.opened() } }
        }
        return RemoteHarnessClient(api, credentials, state, sockets, crypto, clock, { ByteArray(32) { 2 } },
            { "00000000-0000-4000-8000-${(++identifier).toString().padStart(12, '0')}" }, recovery)
    }
    private inner class Socket(val listener: RemoteHarnessClientSocketListener, val schedule: (() -> Unit) -> Unit,
        val connectionID: String) : RemoteHarnessClientSocket {
        private var ended = false
        private var sequence = 0L
        private var event = 0
        private val streams = mutableMapOf<String, String>()
        private val fragments = RemoteHarnessFragments(1)
        override fun send(bytes: ByteArray) {
            check(!ended)
            val root = RemoteHarnessJSON.parse(bytes).objectValue()
            val payload = root.required("payload").objectValue()
            when (root.string("type")) {
                "hello" -> control("hello.ack", obj("protocol" to num(1), "serverVersion" to str("synthetic"),
                    "connectionSessionId" to str("fixture-control"), "heartbeatIntervalMs" to num(25_000),
                    "maxControlFrameBytes" to num(65_536), "maxRelayFrameBytes" to num(1_048_576),
                    "capabilities" to array(str("transport.relay"))))
                "connect.request" -> control("connect.accepted", obj("connectionId" to str(connectionID)))
                "transport.selected" -> check(payload.string("connectionId") == connectionID)
                "secure.handshake" -> deliver(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Handshake(
                    RemoteHarnessSecureHandshake(connectionID, deviceID, 2, byteArrayOf(2))), "handshake-${++event}", now))
                "relay" -> {
                    val relay = (RemoteHarnessControlWire.decode(bytes).packet as RemoteHarnessControlPacket.Relay).value
                    business(RemoteHarnessCodec.decode(relay.ciphertext.copyOfRange(16, relay.ciphertext.size)))
                }
                "pong" -> Unit
                "ping" -> control("pong", obj("nonce" to payload.required("nonce")))
                else -> error("Unexpected synthetic control")
            }
        }
        private fun business(request: RemoteHarnessFrame) {
            val params = request.payload.values.required("params").objectValue()
            fun response(value: RemoteHarnessJSON) = businessFrame("rpc.response", obj("requestId" to str(request.id), "result" to value))
            when (request.payload.values.string("method")) {
                RemoteHarnessCodec.DESCRIBE -> response(obj("capabilities" to array(str("harness.remote.v3"),
                    str("quenderin.approvals.v1"), str(RemoteHarnessBotRead.CARRIER_CAPABILITY), str(RemoteHarnessBotRead.CAPABILITY))))
                RemoteHarnessBotRead.METHOD -> {
                    val revision = botReads.incrementAndGet()
                    response(obj("status" to num(200), "json" to obj("ok" to bool(true), "value" to obj(
                        "schemaVersion" to num(1), "workspaceId" to str("workspace-a"), "revision" to num(revision.toLong()),
                        "readOnly" to bool(true), "bots" to array(obj("id" to str("bot-a"), "name" to str("Synthetic researcher"),
                            "sessionId" to str("bot-session"), "model" to str("deepseek-flash"), "permission" to str("ask"))))))
                }
                RemoteHarnessCodec.OPEN -> {
                    val endpoint = params.string("endpoint"); val streamID = params.string("streamId"); streams[endpoint] = streamID
                    response(obj("opened" to bool(true), "streamId" to str(streamID)))
                    when (endpoint) {
                        "workspace/follow" -> stream(endpoint, obj("type" to str("baseline"), "value" to obj("items" to array(
                            obj("workspaceId" to str("workspace-a"), "title" to str("Synthetic workspace"), "path" to str("/synthetic/project"),
                                "sessionIds" to array(str("bot-session"), str("ordinary-session")))),
                            "archivedSessionIds" to array(), "pinnedSessionIds" to array())))
                        "session/follow" -> {
                            val session = params.required("payload").objectValue().required("args").objectValue().required("request").objectValue()
                                .required("address").objectValue().string("sessionId")
                            check(session in setOf("bot-session", "ordinary-session"))
                            lastFollowSession.set(session)
                            val label = if (session == "bot-session") "Bot" else "ordinary"
                            stream(endpoint, obj("type" to str("snapshot"), "header" to obj("id" to str(session)), "cursor" to num(3),
                                "records" to array(record(1, "user/message", obj("content" to array(obj("type" to str("text"), "text" to str("Synthetic saved $label task"))))),
                                    record(2, "assistant/message", obj("message" to obj("content" to array(obj("type" to str("text"), "text" to str("Synthetic saved $label answer")))))),
                                    record(3, "turn/end", obj("turn" to num(0), "reason" to obj("kind" to str("completed"))))),
                                "hasMore" to bool(false), "projections" to obj("asOfSeq" to num(3), "values" to obj())))
                        }
                        "session/control" -> stream(endpoint, obj("type" to str("baseline"), "value" to obj("projections" to obj())))
                        "\$events" -> stream(endpoint, obj("type" to str("ready"), "clientId" to str("synthetic-gateway")))
                        else -> error("Unexpected synthetic stream")
                    }
                }
                RemoteHarnessCodec.CALL -> {
                    val endpoint = params.string("endpoint")
                    val value = when (endpoint) {
                        "session/list" -> obj("items" to array(*listOf("bot-session", "ordinary-session").map { id ->
                            obj("sessionId" to str(id), "updatedAt" to num(now), "running" to bool(false), "blank" to bool(false)) }.toTypedArray()))
                        "session/modelCatalog" -> obj("default" to obj("provider" to str("deepseek"), "model" to str("host-model")),
                            "routableProviders" to array(str("deepseek")), "failures" to array(), "groups" to array(
                                obj("id" to str("deepseek"), "name" to str("DeepSeek"), "models" to array(
                                    obj("id" to str("host-model"), "name" to str("Synthetic model"), "reasoning" to obj("efforts" to array()))))))
                        "session/prompt" -> { prompts.incrementAndGet(); error("Bot journey must not send prompts") }
                        "session/selectModel" -> { modelChanges.incrementAndGet(); error("Bot journey must not change models") }
                        else -> error("Unexpected synthetic endpoint: $endpoint")
                    }
                    response(obj("ok" to bool(true), "value" to value))
                }
                else -> error("Unexpected synthetic method")
            }
        }
        private fun record(seq: Long, kind: String, data: RemoteHarnessJSON) = obj("type" to str("event"),
            "event" to obj("type" to str(kind), "seq" to num(seq), "time" to num(now), "data" to data))
        private fun stream(endpoint: String, value: RemoteHarnessJSON) = businessFrame("event", obj("event" to str(RemoteHarnessCodec.STREAM_FRAME),
            "data" to obj("streamId" to str(streams.getValue(endpoint)), "hasValue" to bool(true), "value" to value)))
        private fun control(kind: String, payload: RemoteHarnessJSON) = deliver(RemoteHarnessJSON.write(obj("v" to num(1),
            "id" to str("control-${++event}"), "type" to str(kind), "timestamp" to num(now), "payload" to payload)).toByteArray())
        private fun businessFrame(kind: String, payload: RemoteHarnessJSON) {
            val plain = RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("business-${++event}"), "type" to str(kind),
                "timestamp" to num(now), "payload" to payload)).toByteArray()
            fragments.encode(plain, 1).forEach { fragment -> deliver(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Relay(
                RemoteHarnessSecureRelay(connectionID, deviceID, sequence++, ByteArray(16) + fragment.data)), "wire-${++event}", now)) }
        }
        private fun deliver(bytes: ByteArray) { schedule { if (!ended) listener.received(bytes) } }
        override fun checkDeadline(now: Long) {}
        override fun close() { ended = true }
    }
}
private fun Map<String, RemoteHarnessJSON>.required(key: String) = getValue(key)
private fun Map<String, RemoteHarnessJSON>.string(key: String) = required(key).stringValue()
private fun array(vararg values: RemoteHarnessJSON) = RemoteHarnessJSON.ArrayValue(values.toList())
private fun bool(value: Boolean) = RemoteHarnessJSON.BooleanValue(value)
