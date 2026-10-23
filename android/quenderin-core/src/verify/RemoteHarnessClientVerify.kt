package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.security.MessageDigest

/** Synthetic self-hosted relay + official Gateway-shaped frames. No provider, Host, TLS or native
 * crypto claims: the deliberately fake Noise exists only in this verification source set. */
private class ClientClock : RemoteHarnessClock {
    var now = 1_800_000_000_000L; var mono = 1_000L
    override fun epochMilliseconds() = now
    override fun monotonicMilliseconds() = mono
}
private class ClientCredentials : RemoteHarnessClientCredentialStore {
    var source: String? = null; var failWrite = false; var failRead = false
    override fun read(): RemoteHarnessClientCredentials? {
        if (failRead) throw IllegalStateException("fixture storage")
        return source?.let(RemoteHarnessClientRecords::credentials)
    }
    override fun write(record: RemoteHarnessClientCredentials) {
        if (failWrite) throw IllegalStateException("fixture storage")
        source = RemoteHarnessClientRecords.credentials(record)
    }
}
private class ClientState : RemoteHarnessClientStateStore {
    var source: String? = null; var failWrite = false
    override fun read() = source?.let(RemoteHarnessClientRecords::state)
    override fun write(state: RemoteHarnessClientSavedState) {
        if (failWrite) throw IllegalStateException("fixture state")
        source = RemoteHarnessClientRecords.state(state)
    }
}
private class SyntheticClientCrypto : RemoteHarnessCryptoBackend {
    override val isAvailable = true
    override fun publicKey(privateSeed: ByteArray) = ByteArray(32) { 7 }
    override fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo) = object : RemoteHarnessSecureNoise {
        var complete = false; var sending = 0L; var receiving = 0L
        override fun initiate(emptyPayload: ByteArray) = byteArrayOf(1)
        override fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult { complete = true; return RemoteHarnessSecureHandshakeResult(true, byteArrayOf()) }
        override fun counters() = RemoteHarnessSecureCounters(complete, sending, receiving)
        override fun encrypt(plaintext: ByteArray): ByteArray { sending++; return ByteArray(16) + plaintext }
        override fun decrypt(ciphertext: ByteArray): ByteArray { receiving++; return ciphertext.copyOfRange(16, ciphertext.size) }
        override fun shutdown() {}
    }
}
private class ClientFixture(val clock: ClientClock = ClientClock(), val credentials: ClientCredentials = ClientCredentials(),
    val saved: ClientState = ClientState()) : RemoteHarnessClientAPI, RemoteHarnessClientSocketFactory {
    val queue = java.util.ArrayDeque<() -> Unit>()
    val hosts = listOf(RemoteHarnessClientHost("host-a", "My laptop", "account-fixture", true))
    var key = ByteArray(32) { 8 }; var logins = 0; var registrations = 0; var refreshes = 0; var prompts = 0
    var failRefresh = false; var badMembership = false; var connectionCount = 0; var selectedRelay = false
    var clientDeviceID = ""; var sequence = 3L; var eventCounter = 0L
    val sessions = mutableListOf("session-a")
    var current: FixtureSocket? = null
    var hostClockOffset = 0L
    var promptResult: RemoteHarnessJSON? = null
    var assistantRevision = 0L
    var companion = true
    var creates = 0; var modelSelections = 0; var cancellations = 0
    val rejectedLoginOrigins = mutableSetOf<String>()
    var id = 0
    fun newClient(crypto: RemoteHarnessCryptoBackend = SyntheticClientCrypto()) = RemoteHarnessClient(this, credentials, saved, this,
        crypto, clock, { ByteArray(32) { 2 } }, { "00000000-0000-4000-8000-${(++id).toString().padStart(12, '0')}" })
    fun pump() { var limit = 0; while (queue.isNotEmpty()) { check(++limit < 500); queue.removeFirst().invoke() } }
    override fun login(origin: String, email: String, password: CharArray): RemoteHarnessClientLogin {
        logins++
        if (origin in rejectedLoginOrigins) throw RemoteHarnessException("client-auth")
        return RemoteHarnessClientLogin("account_token", clock.now + 8 * 3_600_000)
    }
    override fun register(record: RemoteHarnessClientCredentials, accountToken: String, publicIdentity: String): RemoteHarnessClientTokenPair {
        check(credentials.read()?.deviceID == record.deviceID && credentials.read()?.origin == record.origin)
        check(publicIdentity.length == 43) // Durable identity reservation precedes every registration.
        clientDeviceID = record.deviceID; registrations++; return pair()
    }
    fun pair(refreshExpiry: Long = clock.now + 30L * 86_400_000) = RemoteHarnessClientTokenPair("access_${refreshes}_$registrations",
        clock.now + 3_600_000, "refresh_${refreshes}_$registrations", refreshExpiry)
    override fun refresh(record: RemoteHarnessClientCredentials): RemoteHarnessClientTokenPair {
        check(credentials.read()?.phase == RemoteHarnessCredentialPhase.REFRESH_PENDING)
        refreshes++; if (failRefresh) throw IllegalStateException("lost refresh response")
        return pair(record.refreshExpiresAt)
    }
    override fun hosts(record: RemoteHarnessClientCredentials) = hosts
    override fun host(record: RemoteHarnessClientCredentials, summary: RemoteHarnessClientHost) = RemoteHarnessClientHost(summary.deviceID,
        summary.name, if (badMembership) "different-account" else summary.membershipID, true, key, RemoteHarnessClientRecords.fingerprint(key))
    override fun revoke(record: RemoteHarnessClientCredentials) {}
    override fun connect(origin: String, listener: RemoteHarnessClientSocketListener): RemoteHarnessClientSocket {
        val socket = FixtureSocket(listener, "noise-connection-${++connectionCount}")
        current = socket; queue.add { listener.opened() }; return socket
    }
    fun workspace() = obj("workspaceId" to str("workspace-a"), "title" to str("Project"), "path" to str("/computer/project"),
        "sessionIds" to RemoteHarnessJSON.ArrayValue(sessions.map(::str)))
    inner class FixtureSocket(val listener: RemoteHarnessClientSocketListener, val connectionID: String) : RemoteHarnessClientSocket {
        var ended = false; var sending = 0L
        val streams = linkedMapOf<String, String>()
        override fun send(bytes: ByteArray) {
            check(!ended)
            val root = RemoteHarnessJSON.parse(bytes).objectValue(); val type = root.rhString("type"); val payload = root.rhRequired("payload").objectValue()
            when (type) {
                "hello" -> {
                    check(payload.rhString("deviceId") == clientDeviceID)
                    frame("hello.ack", obj("protocol" to num(1), "serverVersion" to str("fixture"), "connectionSessionId" to str("not-the-noise-id"),
                        "heartbeatIntervalMs" to num(25_000), "maxControlFrameBytes" to num(65_536), "maxRelayFrameBytes" to num(1_048_576),
                        "capabilities" to RemoteHarnessJSON.ArrayValue(listOf(str("transport.relay")))))
                }
                "connect.request" -> frame("connect.accepted", obj("connectionId" to str(connectionID)))
                "transport.selected" -> { check(payload.rhString("connectionId") == connectionID); selectedRelay = true }
                "secure.handshake" -> {
                    check(selectedRelay && payload.rhString("connectionId") == connectionID)
                    val packet = RemoteHarnessControlPacket.Handshake(RemoteHarnessSecureHandshake(connectionID, clientDeviceID, 2, byteArrayOf(2)))
                    val encoded = RemoteHarnessControlWire.encode(packet, "host-control-${++eventCounter}", clock.now)
                    queue.add { if (!ended) listener.received(encoded) }
                }
                "relay" -> {
                    val packet = RemoteHarnessControlWire.decode(bytes).packet as RemoteHarnessControlPacket.Relay
                    check(packet.value.connectionID == connectionID)
                    business(RemoteHarnessCodec.decode(packet.value.ciphertext.copyOfRange(16, packet.value.ciphertext.size)))
                }
                "ping" -> frame("pong", obj("nonce" to payload.rhRequired("nonce")))
                "pong" -> {}
                else -> error("fixture unexpected control")
            }
        }
        fun frame(type: String, payload: RemoteHarnessJSON) {
            val bytes = RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("server-${++eventCounter}"), "type" to str(type),
                "timestamp" to num(clock.now), "payload" to payload)).toByteArray()
            queue.add { if (!ended) listener.received(bytes) }
        }
        fun business(request: RemoteHarnessFrame) {
            val payload = request.payload.values; val method = payload.rhString("method"); val p = payload.rhRequired("params").objectValue()
            fun response(result: RemoteHarnessJSON) = sendBusiness("rpc.response", obj("requestId" to str(request.id), "result" to result))
            when (method) {
                RemoteHarnessCodec.DESCRIBE -> response(obj("capabilities" to RemoteHarnessJSON.ArrayValue(
                    listOf(str("harness.remote.v3")) + if (companion) listOf(str("quenderin.approvals.v1")) else emptyList())))
                RemoteHarnessCodec.OPEN -> {
                    val endpoint = p.rhString("endpoint"); val stream = p.rhString("streamId"); streams[endpoint] = stream
                    response(obj("opened" to RemoteHarnessJSON.BooleanValue(true), "streamId" to str(stream)))
                    when (endpoint) {
                        "workspace/follow" -> event(endpoint, obj("type" to str("baseline"), "value" to obj("items" to RemoteHarnessJSON.ArrayValue(listOf(workspace())),
                            "archivedSessionIds" to RemoteHarnessJSON.ArrayValue(emptyList()), "pinnedSessionIds" to RemoteHarnessJSON.ArrayValue(emptyList()))))
                        "session/follow" -> {
                            val session = p.rhRequired("payload").objectValue().rhRequired("args").objectValue().rhRequired("request").objectValue()
                                .rhRequired("address").objectValue().rhString("sessionId")
                            val records = listOf(record(1, "user/message", obj("content" to RemoteHarnessJSON.ArrayValue(listOf(obj("type" to str("text"), "text" to str("Earlier task")))))),
                                record(2, "assistant/message", obj("message" to obj("content" to RemoteHarnessJSON.ArrayValue(listOf(obj("type" to str("text"), "text" to str("Earlier answer"))))))),
                                record(3, "turn/end", obj("turn" to num(0), "reason" to obj("kind" to str("completed")))))
                            event(endpoint, obj("type" to str("snapshot"), "header" to obj("id" to str(session)), "cursor" to num(sequence),
                                "records" to RemoteHarnessJSON.ArrayValue(records), "hasMore" to RemoteHarnessJSON.BooleanValue(false),
                                "projections" to obj("asOfSeq" to num(sequence), "values" to obj())))
                        }
                        "session/control" -> event(endpoint, obj("type" to str("baseline"), "value" to obj("projections" to obj())))
                        "\$events" -> event(endpoint, obj("type" to str("ready"), "clientId" to str("gateway-client")))
                    }
                }
                RemoteHarnessCodec.CALL -> {
                    val endpoint = p.rhString("endpoint"); val args = p.rhRequired("payload").objectValue().rhRequired("args").objectValue()
                    val result = when (endpoint) {
                        "session/list" -> obj("items" to RemoteHarnessJSON.ArrayValue((sessions + "other-workspace-session").map { id -> obj("sessionId" to str(id),
                            "updatedAt" to num(clock.now), "running" to RemoteHarnessJSON.BooleanValue(false), "blank" to RemoteHarnessJSON.BooleanValue(false)) }))
                        "session/create" -> { creates++; sessions.add("session-b"); obj("sessionId" to str("session-b")) }
                        "session/modelCatalog" -> obj("default" to obj("provider" to str("deepseek"), "model" to str("host-model")),
                            "routableProviders" to RemoteHarnessJSON.ArrayValue(listOf(str("deepseek"))), "failures" to RemoteHarnessJSON.ArrayValue(emptyList()),
                            "groups" to RemoteHarnessJSON.ArrayValue(listOf(obj("id" to str("deepseek"), "name" to str("DeepSeek"),
                                "models" to RemoteHarnessJSON.ArrayValue(listOf(obj("id" to str("host-model"), "name" to str("Host model"),
                                    "reasoning" to obj("efforts" to RemoteHarnessJSON.ArrayValue(listOf(obj("id" to str("high"), "name" to str("High"))))))))))))
                        "session/selectModel" -> { modelSelections++; val r = args.rhRequired("request").objectValue(); obj("selected" to obj("provider" to r.rhRequired("provider"),
                            "model" to r.rhRequired("model"), "reasoningEffort" to r["reasoningEffort"])) }
                        "session/prompt" -> { prompts++; promptResult }
                        "session/cancel" -> { cancellations++; obj("accepted" to RemoteHarnessJSON.BooleanValue(true)) }
                        "quenderin/approval" -> obj("accepted" to RemoteHarnessJSON.BooleanValue(true))
                        else -> error("fixture unexpected endpoint $endpoint")
                    }
                    response(obj("ok" to RemoteHarnessJSON.BooleanValue(true), "value" to result))
                    if (endpoint == "session/prompt") {
                        event("session/follow", record(++sequence, "turn/start", obj("turn" to num(1))))
                        event("session/follow", record(++sequence, "user/message", obj("content" to RemoteHarnessJSON.ArrayValue(listOf(obj("type" to str("text"), "text" to str("New task")))))))
                        assistant(obj("type" to str("start"), "attemptId" to str("attempt-a"), "revision" to num(++assistantRevision), "turn" to num(1), "step" to num(1), "startedAfterSeq" to num(sequence)))
                        assistant(obj("type" to str("chunk"), "attemptId" to str("attempt-a"), "revision" to num(++assistantRevision), "index" to num(0), "time" to num(clock.now),
                            "chunk" to obj("type" to str("text-delta"), "index" to num(0), "text" to str("Streaming answer"))))
                        assistant(obj("type" to str("chunk"), "attemptId" to str("attempt-a"), "revision" to num(++assistantRevision), "index" to num(1), "time" to num(clock.now),
                            "chunk" to obj("type" to str("reasoning-delta"), "index" to num(1), "text" to str("Visible reasoning"))))
                        event("session/follow", record(++sequence, "tool/call", obj("turn" to num(1), "step" to num(1), "callId" to str("tool-a"),
                            "name" to str("shell"), "arguments" to str("{\"command\":\"pwd\"}"))))
                        approval("approval-a")
                    }
                }
                else -> error("fixture unexpected method")
            }
        }
        fun record(seq: Long, type: String, data: RemoteHarnessJSON) = obj("type" to str("event"), "event" to obj("type" to str(type),
            "seq" to num(seq), "time" to num(clock.now), "data" to data))
        fun assistant(value: RemoteHarnessJSON) = event("session/follow", obj("type" to str("assistant-stream"), "frame" to value))
        fun approval(id: String, session: String = "session-b") {
            val request = obj("reason" to str("Read current directory"), "toolName" to str("shell"))
            val digest = MessageDigest.getInstance("SHA-256").digest("{\"reason\":\"Read current directory\",\"toolName\":\"shell\"}".toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 255) }
            event("\$events", obj("type" to str("waterfall"), "event" to str("approval/request"), "eventId" to str(id), "agentId" to str(session),
                "request" to request, "quenderinBinding" to obj("hostDeviceId" to str("host-a"), "clientDeviceId" to str(clientDeviceID),
                    "workspaceId" to str("workspace-a"), "sessionId" to str(session), "runId" to str("turn:1"), "eventId" to str(id),
                    "actionDigest" to str(digest), "expiresAt" to num(clock.now + hostClockOffset + 120_000))))
        }
        fun event(endpoint: String, value: RemoteHarnessJSON) {
            val stream = streams[endpoint] ?: return
            sendBusiness("event", obj("event" to str(RemoteHarnessCodec.STREAM_FRAME), "data" to obj("streamId" to str(stream),
                "hasValue" to RemoteHarnessJSON.BooleanValue(true), "value" to value)))
        }
        fun sendBusiness(type: String, payload: RemoteHarnessJSON) {
            val plain = RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("business-${++eventCounter}"), "type" to str(type),
                "timestamp" to num(clock.now + hostClockOffset), "payload" to payload)).toByteArray()
            val packet = RemoteHarnessControlPacket.Relay(RemoteHarnessSecureRelay(connectionID, clientDeviceID, sending++, ByteArray(16) + plain))
            val bytes = RemoteHarnessControlWire.encode(packet, "wire-${++eventCounter}", clock.now)
            queue.add { if (!ended) listener.received(bytes) }
        }
        override fun checkDeadline(now: Long) {}
        override fun close() { ended = true }
    }
}

fun main(args: Array<String>) {
    var checks = 0
    fun verify(value: Boolean, message: String) { check(value) { message }; checks++ }
    val digestFixtures = RemoteHarnessJSON.parse(java.io.File(args.firstOrNull() ?: "shared/remote-harness-approval-digest-fixtures.json").readText()).objectValue()
    for (case in (digestFixtures.rhRequired("cases") as RemoteHarnessJSON.ArrayValue).values) {
        val fixture = case.objectValue(); val value = RemoteHarnessJSON.parse(fixture.rhString("wireJSON"))
        if (fixture.rhString("nativeExpectation") == "digest") {
            verify(RemoteHarnessClientApprovalGate.actionDigest(value) == fixture.rhString("sha256"), "shared Host digest ${fixture.rhString("id")}")
        } else {
            var rejected = false
            try { RemoteHarnessClientApprovalGate.actionDigest(value) } catch (error: RemoteHarnessException) { rejected = error.code == "approval-action" }
            verify(rejected, "unsupported numeric action fails closed ${fixture.rhString("id")}")
        }
    }
    val fixture = ClientFixture(); val client = fixture.newClient()
    val password = "fixture-only-password".toCharArray()
    client.authorize("https://relay.example.org", "fixture@example.org", password)
    verify(password.all { it == '\u0000' }, "password is zeroed")
    verify(fixture.registrations == 1 && fixture.credentials.read()?.phase == RemoteHarnessCredentialPhase.READY, "durable enrollment")
    client.chooseHost("host-a")
    verify(client.snapshot.phase == RemoteHarnessClientPhase.CONFIRM_PIN && fixture.connectionCount == 0, "explicit full pin")
    client.confirmHost(client.snapshot.pendingHost!!.fingerprint!!); fixture.pump()
    verify(client.snapshot.workspaces.single().id == "workspace-a" && client.snapshot.workspaceID == null, "discovery without profile")
    verify(fixture.selectedRelay, "relay selected using actual Noise connection ID")
    client.chooseWorkspace("workspace-a"); fixture.pump()
    verify(client.snapshot.sessions.map { it.id } == listOf("session-a"), "actual workspace session scope")
    client.createSession(); fixture.pump()
    verify(client.snapshot.sessionID == "session-b" && client.snapshot.historyReady, "create/open/follow session: ${client.snapshot.phase} ${client.snapshot.error}")
    verify(client.snapshot.timeline.any { it.text == "Earlier answer" }, "authoritative history")
    client.selectModel("deepseek", "host-model", "high"); fixture.pump()
    verify(client.snapshot.effort == "high", "actual Host model effort")
    client.draft("New task"); client.send(); client.send(); fixture.pump()
    verify(fixture.prompts == 1, "send once despite double tap")
    verify(client.snapshot.timeline.any { it.text == "Streaming answer" && it.reasoning == "Visible reasoning" }, "stream text and reasoning")
    verify(client.snapshot.timeline.any { it.kind == "tool" && it.text.contains("pwd") }, "native tool timeline")
    verify(client.snapshot.approvals.single().eventID == "approval-a", "bound approval admitted")
    client.decideApproval("approval-a", true); fixture.pump()
    verify(client.snapshot.approvals.isEmpty(), "approval consumed once")
    fixture.current!!.approval("approval-b"); fixture.pump(); client.decideApproval("approval-b", false); fixture.pump()
    verify(client.snapshot.approvals.isEmpty(), "deny uses same exact binding")
    fixture.current!!.approval("approval-reused"); fixture.pump()
    fixture.current!!.event("\$events", obj("type" to str("waterfall"), "event" to str("approval/request"),
        "eventId" to str("approval-reused"), "agentId" to str("session-b"), "request" to obj("toolName" to str("different-tool"))))
    fixture.pump(); verify(client.snapshot.approvals.isEmpty(), "reused event ID invalidates old action even without binding")
    fixture.hostClockOffset = 60_000
    fixture.current!!.approval("approval-clock-skew"); fixture.pump()
    verify(client.snapshot.approvals.single().eventID == "approval-clock-skew", "authenticated Host time supports wall clock skew")
    fixture.clock.mono += 120_001; client.tick(); fixture.pump()
    verify(client.snapshot.approvals.isEmpty(), "approval monotonic expiry")
    fixture.hostClockOffset = 0
    client.stop(); fixture.pump()
    verify(client.snapshot.status == RemoteSessionStatus.STOP_REQUESTED, "stop receipt is not stopped")
    fixture.current!!.event("session/follow", fixture.current!!.record(++fixture.sequence, "turn/end", obj("turn" to num(1), "reason" to obj("kind" to str("aborted")))))
    fixture.pump(); verify(client.snapshot.status == RemoteSessionStatus.STOPPED, "authoritative aborted turn")
    fixture.promptResult = str("receipt-only")
    client.draft("Another task"); client.send(); fixture.pump()
    verify(client.snapshot.historyReady && client.snapshot.draft.isEmpty() && fixture.prompts == 2, "arbitrary successful prompt result is receipt only")
    client.draft("Keep this draft"); val old = fixture.current!!; client.disconnect()
    val relaunched = fixture.newClient()
    verify(relaunched.snapshot.sessionID == "session-b" && relaunched.snapshot.draft == "Keep this draft" && relaunched.snapshot.timeline.isNotEmpty(), "process recovery retains scoped history/draft")
    relaunched.resume(); fixture.pump()
    verify(relaunched.snapshot.sessionID == "session-b" && relaunched.snapshot.historyReady && relaunched.snapshot.draft == "Keep this draft", "explicit authoritative reconnect")
    old.listener.closed(); verify(relaunched.snapshot.historyReady, "old callback cannot retire replacement owner")

    val storageFixture = ClientFixture(); storageFixture.credentials.failWrite = true
    val unsaved = storageFixture.newClient(); unsaved.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(storageFixture.logins == 1 && storageFixture.registrations == 0, "failed identity reservation never registers a device")
    val unavailable = ClientFixture(); val noSDK = unavailable.newClient(object : RemoteHarnessCryptoBackend {
        override val isAvailable = false
        override fun publicKey(privateSeed: ByteArray): ByteArray = error("unavailable")
        override fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo): RemoteHarnessSecureNoise = error("unavailable")
    })
    noSDK.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(unavailable.logins == 0 && unavailable.credentials.read() == null, "absent real SDK blocks credential dispatch")
    val failedRefresh = ClientFixture(); val first = failedRefresh.newClient()
    first.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    val identity = failedRefresh.credentials.read()!!.deviceID
    failedRefresh.clock.now += 3_550_000; failedRefresh.failRefresh = true; first.resume(); first.resume()
    verify(failedRefresh.refreshes == 1 && failedRefresh.credentials.read()?.phase == RemoteHarnessCredentialPhase.REFRESH_PENDING, "lost refresh response is never replayed")
    val afterLoss = failedRefresh.newClient(); afterLoss.resume()
    verify(failedRefresh.refreshes == 1, "refresh reservation survives process death")
    failedRefresh.clock.now += 20_000
    afterLoss.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(failedRefresh.credentials.read()?.deviceID == identity && failedRefresh.credentials.read()?.phase == RemoteHarnessCredentialPhase.READY &&
        afterLoss.snapshot.phase == RemoteHarnessClientPhase.HOSTS && afterLoss.snapshot.hosts.isNotEmpty(), "reauthorization restores READY and Host discovery with same identity")
    val corrupt = ClientFixture(); corrupt.credentials.failRead = true; val corrupted = corrupt.newClient()
    corrupted.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(corrupt.logins == 0, "failed reads never silently reset")
    fixture.key = ByteArray(32) { 9 }; relaunched.disconnect(); relaunched.resume(); fixture.pump()
    verify(relaunched.snapshot.error?.contains("identity changed") == true && !relaunched.snapshot.historyReady, "changed pin cannot replace trust")
    val plain = ClientFixture().apply { companion = false }; val readOnly = plain.newClient()
    readOnly.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray()); readOnly.chooseHost("host-a")
    readOnly.confirmHost(readOnly.snapshot.pendingHost!!.fingerprint!!); plain.pump()
    verify(readOnly.snapshot.workspaces.isNotEmpty() && !readOnly.snapshot.approvalSupported, "plain V3 retains read-only discovery")
    readOnly.chooseWorkspace("workspace-a"); plain.pump(); readOnly.createSession(); plain.pump()
    verify(plain.creates == 0 && readOnly.snapshot.error?.contains("companion") == true, "plain V3 cannot create sessions")
    readOnly.chooseSession("session-a"); plain.pump()
    verify(readOnly.snapshot.historyReady && readOnly.snapshot.timeline.any { it.text == "Earlier answer" }, "plain V3 retains existing authoritative history")
    readOnly.draft("Keep read-only draft"); readOnly.send(); readOnly.selectModel("deepseek", "host-model", "high"); plain.pump()
    verify(plain.prompts == 0 && plain.modelSelections == 0 && readOnly.snapshot.draft == "Keep read-only draft", "plain V3 cannot prompt or change models")
    readOnly.stop(); plain.pump()
    verify(plain.cancellations == 1 && readOnly.snapshot.status == RemoteSessionStatus.STOP_REQUESTED, "plain V3 retains truthful Stop for recovery")
    val typo = ClientFixture().apply { rejectedLoginOrigins.add("https://wrong.example.org") }; val setup = typo.newClient()
    setup.authorize("https://wrong.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(typo.credentials.read() == null && setup.snapshot.origin.isEmpty() && setup.snapshot.deviceID.isEmpty(), "failed initial login preserves editable server")
    setup.authorize("https://relay.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(typo.credentials.read()?.phase == RemoteHarnessCredentialPhase.READY && typo.credentials.read()?.origin == "https://relay.example.org" &&
        typo.registrations == 1 && setup.snapshot.phase == RemoteHarnessClientPhase.HOSTS, "corrected server durably reserves before registration and reaches READY")
    val boundIdentity = typo.credentials.read()!!.deviceID
    setup.authorize("https://other.example.org", "fixture@example.org", "fixture".toCharArray())
    verify(typo.credentials.read()?.deviceID == boundIdentity && typo.credentials.read()?.origin == "https://relay.example.org" && typo.registrations == 1,
        "registered device origin and identity cannot be silently replaced")
    println("Remote Harness native Android controller: $checks checks passed (synthetic relay/crypto, no live provider or device).")
}
