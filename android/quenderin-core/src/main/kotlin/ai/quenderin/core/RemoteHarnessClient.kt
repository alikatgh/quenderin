package ai.quenderin.core

import ai.quenderin.core.RemoteHarnessJSON.Companion.num
import ai.quenderin.core.RemoteHarnessJSON.Companion.obj
import ai.quenderin.core.RemoteHarnessJSON.Companion.str
import java.util.Base64

/** One native remote journey. All methods, REST calls and socket callbacks share its owner thread.
 * No provider keys, local conversation readers, worker jobs or mutation replay enter this owner. */
class RemoteHarnessClient(
    private val api: RemoteHarnessClientAPI,
    private val credentials: RemoteHarnessClientCredentialStore,
    private val persistence: RemoteHarnessClientStateStore,
    private val sockets: RemoteHarnessClientSocketFactory,
    private val crypto: RemoteHarnessCryptoBackend,
    private val clock: RemoteHarnessClock,
    private val randomSeed: () -> ByteArray,
    private val identifier: () -> String,
) {
    private val ownerThread = Thread.currentThread()
    private var storageFailureMessage: String? = null
    var onChange: ((RemoteHarnessClientSnapshot) -> Unit)? = null
    var snapshot = RemoteHarnessClientSnapshot(); private set
    private var record: RemoteHarnessClientCredentials? = null
    private var saved: RemoteHarnessClientSavedState? = null
    private var trustedHost: RemoteHarnessClientHost? = null
    private var socket: RemoteHarnessClientSocket? = null
    private var link: RemoteHarnessSecureLink? = null
    private var coordinator: RemoteHarnessCoordinator? = null
    private var context: RemoteHarnessAuthenticatedContext? = null
    private var generation = 0L
    private var controlID = 0L
    private var stage = "idle"
    private var setupDeadline = 0L
    private var helloDeadline = 0L
    private var nextPing = 0L
    private var pingNonce: String? = null
    private var pingDeadline = 0L
    private var limits = RemoteHarnessControlWireLimits()
    private var workspaceBaseline = false
    private var scopedStarted = false
    private var historyCursor = 0L
    private var pageCursor: Long? = null
    private var historyThrough = 0L
    private var historyBytes = 0
    private var activeAttempt: String? = null
    private var attemptCommitted = false
    private var attemptRevision = 0L
    private var attemptIndex = 0L
    private var knownCommands = linkedSetOf<String>()
    private val approvalActionEvidence = RemoteHarnessClientApprovalActions()

    init {
        try {
            record = credentials.read(); saved = persistence.read()
            val r = record; val s = saved
            rhCheck(s == null || r != null && s.origin == r.origin && s.deviceID == r.deviceID, "client-storage")
            knownCommands.addAll(s?.commands ?: emptyList())
            snapshot = snapshot.copy(origin = r?.origin ?: "", deviceID = r?.deviceID ?: "",
                workspaceID = s?.workspaceID, workspaceTitle = s?.workspaceTitle ?: "", sessionID = s?.sessionID,
                timeline = s?.timeline ?: emptyList(), draft = s?.draft ?: "", provider = s?.provider,
                model = s?.model, effort = s?.effort,
                phase = if (r == null) RemoteHarnessClientPhase.SETUP else RemoteHarnessClientPhase.DISCONNECTED,
                status = if (knownCommands.isEmpty()) RemoteSessionStatus.DISCONNECTED else RemoteSessionStatus.OUTCOME_UNKNOWN)
            if (r?.phase == RemoteHarnessCredentialPhase.REFRESH_PENDING) block("A token refresh was interrupted. Sign in again to authorize this same device.", storageFailure = false)
            if (r != null && crypto.isAvailable) showIdentity(r)
        } catch (_: Exception) { block("Saved computer connection could not be read. Keep the existing data and repair secure storage before continuing.") }
        if (!crypto.isAvailable && snapshot.phase != RemoteHarnessClientPhase.BLOCKED)
            update(snapshot.copy(error = "Remote security SDK is unavailable in this build. Install a build with the native Remote SDK before entering credentials."))
    }
    override fun toString() = "RemoteHarnessClient(redacted)"
    private fun owner() = rhCheck(Thread.currentThread() === ownerThread, "client-owner")
    private fun update(value: RemoteHarnessClientSnapshot) {
        snapshot = storageFailureMessage?.let { value.copy(phase = RemoteHarnessClientPhase.BLOCKED, busy = false, historyReady = false, error = it) } ?: value
        onChange?.invoke(snapshot)
    }
    private fun block(message: String, storageFailure: Boolean = true) {
        if (storageFailure) storageFailureMessage = message
        update(snapshot.copy(phase = RemoteHarnessClientPhase.BLOCKED, busy = false, historyReady = false, error = message))
    }
    private inline fun action(body: () -> Unit) {
        owner()
        if (snapshot.busy || storageFailureMessage != null) return
        try { body() } catch (e: RemoteHarnessException) { fail(e.code) }
        catch (_: Exception) { fail("client-connection") }
    }
    private fun fail(code: String) {
        val message = when (code) {
            "client-storage" -> "The computer connection could not be saved. Existing data was retained; repair secure storage before sending."
            "client-crypto" -> "Remote security SDK is unavailable in this build. Install a build with the native Remote SDK before entering credentials."
            "client-companion" -> "Install and enable the Quenderin Remote companion on your computer, approve this device there, then reconnect. This Host is read-only."
            "client-reauthorize" -> "Sign in again to authorize this same device. An interrupted single-use refresh cannot be retried."
            "client-auth" -> "Sign-in was refused. Check the server account email and password."
            "client-host-key" -> "The computer identity changed. Verify the computer and server before establishing new trust."
            "client-origin" -> "Enter the HTTPS origin of your self-hosted Remote server, without a path or credentials."
            "client-bounds" -> "The server exceeded the supported connection limits. Disconnect and check the Host configuration."
            "client-deadline" -> "The computer did not complete the connection in time. Check that the Host is online and accepts this device."
            "client-protocol" -> "This Host returned an unsupported response. Update its Remote companion and reconnect."
            "client-history" -> "History changed or could not be verified. Reconnect to load an authoritative snapshot before sending."
            "approval-action-unverified" -> "The computer's full tool action is not verified yet. Wait for its authoritative call and arguments, or stop the task."
            else -> "The computer connection failed. Check your server and computer, then reconnect explicitly."
        }
        update(snapshot.copy(busy = false, error = message,
            phase = if (code == "client-reauthorize") RemoteHarnessClientPhase.DISCONNECTED else snapshot.phase,
            historyReady = if (code == "client-history") false else snapshot.historyReady))
        if (code == "client-storage") block(message)
    }

    fun authorize(origin: String, email: String, password: CharArray) {
        owner()
        try { action {
            rhCheck(crypto.isAvailable, "client-crypto")
            rhCheck(snapshot.phase != RemoteHarnessClientPhase.BLOCKED || record?.phase == RemoteHarnessCredentialPhase.REFRESH_PENDING,
                "client-storage")
            val canonical = try { ConnectionOrigins.canonicalize(origin) } catch (_: Exception) { throw RemoteHarnessException("client-origin") }
            rhCheck(record == null || record?.origin == canonical, "client-origin")
            rhCheck(email.trim().length in 1..254 && password.size in 1..1024, "client-auth")
            disconnectInternal()
            update(snapshot.copy(phase = RemoteHarnessClientPhase.AUTHORIZING, busy = true, error = null))
            // A rejected first sign-in must not reserve a device forever against a mistyped
            // server. Existing identities stay bound; a NEW identity is reserved after login
            // succeeds and still durably before the first registration request.
            val login = api.login(canonical, email.trim(), password)
            rhCheck(login.expiresAt > clock.epochMilliseconds(), "client-auth")
            if (record == null) {
                val seed = randomSeed()
                try {
                    rhCheck(seed.size == 32, "client-identity")
                    val reserved = RemoteHarnessClientCredentials(canonical, identifier(), seed)
                    writeCredentials(reserved) // Reservation is durable BEFORE device registration.
                } finally { seed.fill(0) }
            }
            val r = record ?: throw RemoteHarnessException("client-storage")
            val publicKey = r.useSeed(crypto::publicKey)
            rhCheck(publicKey.size == 32, "client-crypto")
            val pair = api.register(r, login.token, Base64.getUrlEncoder().withoutPadding().encodeToString(publicKey))
            installPair(r, pair)
            listHosts()
        } } finally { password.fill('\u0000') }
    }

    private fun writeCredentials(next: RemoteHarnessClientCredentials) {
        try {
            credentials.write(next)
            val read = credentials.read() ?: throw RemoteHarnessException("client-storage")
            rhCheck(RemoteHarnessClientRecords.credentials(read) == RemoteHarnessClientRecords.credentials(next), "client-storage")
            record = read
            showIdentity(read)
        } catch (_: Exception) { throw RemoteHarnessException("client-storage") }
    }
    private fun showIdentity(value: RemoteHarnessClientCredentials) {
        val publicKey = value.useSeed(crypto::publicKey)
        rhCheck(publicKey.size == 32, "client-crypto")
        update(snapshot.copy(origin = value.origin, deviceID = value.deviceID,
            clientPublicIdentity = Base64.getUrlEncoder().withoutPadding().encodeToString(publicKey),
            clientFingerprint = RemoteHarnessClientRecords.fingerprint(publicKey)))
    }
    private fun installPair(previous: RemoteHarnessClientCredentials, pair: RemoteHarnessClientTokenPair, refreshing: Boolean = false) {
        val now = clock.epochMilliseconds()
        rhCheck(pair.accessExpiresAt > now && pair.accessExpiresAt <= now + 3_660_000 &&
            pair.refreshExpiresAt > now && pair.refreshExpiresAt <= now + 30L * 86_400_000 + 60_000, "client-protocol")
        if (refreshing)
            rhCheck(pair.refreshExpiresAt == previous.refreshExpiresAt, "client-protocol")
        writeCredentials(previous.replacing(RemoteHarnessCredentialPhase.READY, pair))
    }
    private fun requireAccess(): RemoteHarnessClientCredentials {
        val r = record ?: throw RemoteHarnessException("client-reauthorize")
        rhCheck(r.phase == RemoteHarnessCredentialPhase.READY, "client-reauthorize")
        if (r.accessExpiresAt > clock.epochMilliseconds() + 60_000) return r
        rhCheck(r.refreshExpiresAt > clock.epochMilliseconds(), "client-reauthorize")
        val pending = r.replacing(RemoteHarnessCredentialPhase.REFRESH_PENDING)
        writeCredentials(pending) // Single-use attempt reservation, before HTTP.
        try { installPair(pending, api.refresh(pending), refreshing = true) }
        catch (e: RemoteHarnessException) { if (e.code == "client-storage") throw e; throw RemoteHarnessException("client-reauthorize") }
        catch (_: Exception) { throw RemoteHarnessException("client-reauthorize") }
        return record ?: throw RemoteHarnessException("client-storage")
    }
    fun resume() = action {
        rhCheck(crypto.isAvailable, "client-crypto")
        listHosts()
        val hostID = saved?.hostID
        if (hostID != null) snapshot.hosts.firstOrNull { it.deviceID == hostID }?.let { chooseHostInternal(it) }
    }
    fun refreshHosts() = action { listHosts() }
    private fun listHosts() {
        val r = requireAccess()
        val hosts = api.hosts(r)
        rhCheck(hosts.size <= 256 && hosts.map { it.deviceID }.distinct().size == hosts.size, "client-protocol")
        update(snapshot.copy(phase = RemoteHarnessClientPhase.HOSTS, origin = r.origin, deviceID = r.deviceID,
            hosts = hosts, busy = false, error = null))
    }
    fun chooseHost(id: String) = action {
        val host = snapshot.hosts.singleOrNull { it.deviceID == id } ?: throw RemoteHarnessException("client-protocol")
        chooseHostInternal(host)
    }
    private fun chooseHostInternal(summary: RemoteHarnessClientHost) {
        val host = api.host(requireAccess(), summary)
        rhCheck(host.deviceID == summary.deviceID && host.membershipID == summary.membershipID && host.publicKey?.size == 32 &&
            host.fingerprint == RemoteHarnessClientRecords.fingerprint(host.publicKey), "client-host-key")
        if (saved?.hostID == host.deviceID && saved?.hostFingerprint != null) {
            rhCheck(saved?.hostFingerprint == host.fingerprint, "client-host-key")
            trustedHost = host; update(snapshot.copy(host = host, pendingHost = null)); connect()
        } else update(snapshot.copy(phase = RemoteHarnessClientPhase.CONFIRM_PIN, pendingHost = host, error = null))
    }
    fun confirmHost(fullFingerprint: String) = action {
        val host = snapshot.pendingHost ?: throw RemoteHarnessException("client-host-key")
        rhCheck(fullFingerprint == host.fingerprint, "client-host-key")
        trustedHost = host
        update(snapshot.copy(host = host, pendingHost = null, workspaceID = null, workspaceTitle = "", sessionID = null,
            timeline = emptyList(), historyReady = false, models = emptyList(), provider = null, model = null, effort = null))
        persist(); connect()
    }
    private fun persist() {
        val r = record ?: return
        val host = trustedHost
        val next = RemoteHarnessClientSavedState(r.origin, r.deviceID, host?.deviceID ?: saved?.hostID,
            host?.name ?: saved?.hostName, host?.fingerprint ?: saved?.hostFingerprint, snapshot.workspaceID,
            snapshot.workspaceTitle, snapshot.sessionID, snapshot.draft, snapshot.timeline, knownCommands.toList(),
            snapshot.provider, snapshot.model, snapshot.effort)
        try {
            persistence.write(next)
            val checked = persistence.read() ?: throw RemoteHarnessException("client-storage")
            rhCheck(RemoteHarnessClientRecords.state(next) == RemoteHarnessClientRecords.state(checked), "client-storage")
            saved = checked
        } catch (_: Exception) { throw RemoteHarnessException("client-storage") }
    }
    fun draft(value: String) = action {
        rhCheck(value.toByteArray(Charsets.UTF_8).size <= RemoteHarnessBounds.TEXT_BYTES, "client-bounds")
        update(snapshot.copy(draft = value)); persist()
    }

    private fun connect() {
        val r = requireAccess(); val host = trustedHost ?: throw RemoteHarnessException("client-host-key")
        disconnectInternal(); generation++; val g = generation
        stage = "opening"; setupDeadline = clock.monotonicMilliseconds() + 15_000
        limits = RemoteHarnessControlWireLimits(); workspaceBaseline = false; scopedStarted = false
        update(snapshot.copy(phase = RemoteHarnessClientPhase.CONNECTING, busy = false, historyReady = false,
            status = RemoteSessionStatus.CONNECTING, error = null))
        socket = sockets.connect(r.origin, object : RemoteHarnessClientSocketListener {
            override fun opened() { if (g == generation) guardedSocket {
                rhCheck(stage == "opening", "client-protocol")
                stage = "hello"; helloDeadline = clock.monotonicMilliseconds() + 5_000
                sendControl("hello", obj("role" to str("client"), "deviceId" to str(r.deviceID), "accessToken" to str(r.accessToken!!),
                    "protocols" to RemoteHarnessJSON.ArrayValue(listOf(num(1))), "capabilities" to RemoteHarnessJSON.ArrayValue(listOf(str("transport.relay"))),
                    "clientVersion" to str("quenderin-native/1")))
            } }
            override fun received(bytes: ByteArray) { if (g == generation) guardedSocket { receiveControl(bytes, r, host, g) } }
            override fun closed() { if (g == generation) disconnectInternal() }
        })
    }
    private inline fun guardedSocket(expectedGeneration: Long = generation, body: () -> Unit) {
        owner()
        try { body() } catch (e: RemoteHarnessException) {
            if (expectedGeneration == generation) { disconnectInternal(); fail(e.code) }
        } catch (_: Exception) {
            if (expectedGeneration == generation) { disconnectInternal(); fail("client-protocol") }
        }
    }
    private fun sendControl(type: String, payload: RemoteHarnessJSON) {
        val bytes = RemoteHarnessJSON.write(obj("v" to num(1), "id" to str("native-${++controlID}"), "type" to str(type),
            "timestamp" to num(clock.epochMilliseconds()), "payload" to payload)).toByteArray(Charsets.UTF_8)
        rhCheck(bytes.size <= limits.handshake, "client-bounds")
        (socket ?: throw RemoteHarnessException("client-connection")).send(bytes)
    }
    private fun receiveControl(bytes: ByteArray, r: RemoteHarnessClientCredentials, host: RemoteHarnessClientHost, g: Long) {
        rhCheck(bytes.size <= limits.relay, "client-bounds")
        val root = RemoteHarnessJSON.parse(bytes).objectValue()
        rhCheck(root.rhRequired("v").integerValue() == 1L, "client-protocol")
        rhID(root.rhString("id")); root.rhRequired("timestamp").integerValue(true)
        val type = root.rhString("type"); val p = root.rhRequired("payload").objectValue()
        if (type !in setOf("relay")) rhCheck(bytes.size <= limits.handshake, "client-bounds")
        when (type) {
            "hello.ack" -> {
                rhCheck(stage == "hello" && clock.monotonicMilliseconds() <= helloDeadline && p.rhRequired("protocol").integerValue() == 1L,
                    "client-protocol")
                rhID(p.rhString("connectionSessionId")) // This is deliberately never the Noise connection ID.
                val caps = array(p.rhRequired("capabilities")).map { it.stringValue() }
                rhCheck(caps == listOf("transport.relay"), "client-protocol")
                val interval = p.rhRequired("heartbeatIntervalMs").integerValue(true)
                rhCheck(interval in 1_000..25_000, "client-bounds")
                val controlLimit = p.rhRequired("maxControlFrameBytes").integerValue(true)
                val relayLimit = p.rhRequired("maxRelayFrameBytes").integerValue(true)
                rhCheck(controlLimit in 1..65_536 && relayLimit in 1..1_048_576, "client-bounds")
                limits = RemoteHarnessControlWireLimits(controlLimit, relayLimit)
                nextPing = clock.monotonicMilliseconds() + interval; stage = "accepting"
                sendControl("connect.request", obj("hostDeviceId" to str(host.deviceID),
                    "preferredTransports" to RemoteHarnessJSON.ArrayValue(listOf(str("relay")))))
            }
            "connect.accepted" -> {
                rhCheck(stage == "accepting" && clock.monotonicMilliseconds() <= setupDeadline, "client-protocol")
                val connectionID = p.rhString("connectionId").also(::rhID)
                stage = "noise"
                sendControl("transport.selected", obj("connectionId" to str(connectionID), "targetDeviceId" to str(host.deviceID), "transport" to str("relay")))
                beginSecureLink(r, host, connectionID, g)
            }
            "secure.handshake", "relay" -> {
                val packet = RemoteHarnessControlWire.decode(bytes, limits).packet
                when (packet) {
                    is RemoteHarnessControlPacket.Handshake -> link?.receiveHandshake(packet.value, g)
                    is RemoteHarnessControlPacket.Relay -> link?.receiveRelay(packet.value, g)
                }
            }
            "ping" -> { val nonce = p.rhString("nonce").also(::rhID); sendControl("pong", obj("nonce" to str(nonce))) }
            "pong" -> { rhCheck(p.rhString("nonce") == pingNonce && pingNonce != null, "client-protocol"); pingNonce = null }
            "connect.rejected", "error" -> throw RemoteHarnessException("client-connection")
            else -> throw RemoteHarnessException("client-protocol")
        }
    }
    private fun beginSecureLink(r: RemoteHarnessClientCredentials, host: RemoteHarnessClientHost, connectionID: String, g: Long) {
        val info = RemoteHarnessSecureConnectionInfo(connectionID, r.deviceID, host.deviceID)
        val profile = snapshot.workspaceID?.let { workspace -> ConnectionProfile.create("remote-${r.deviceID}", ConnectionKind.REMOTE_HARNESS,
            host.name, r.origin, hostID = host.deviceID, hostFingerprint = host.fingerprint, workspaceID = workspace) }
        val binding = if (profile == null) RemoteHarnessTransportBinding.discovery("enrollment-${r.deviceID}", r.origin, host.deviceID, host.fingerprint!!)
            else RemoteHarnessTransportBinding.from(ConversationBinding.from(profile))
        val authenticated = RemoteHarnessAuthenticatedContext(binding, r.deviceID, connectionID, g, snapshot.sessionID)
        val packetPort = object : RemoteHarnessSecurePacketPort {
            override fun connectionInfo() = info
            override fun sendHandshake(payload: RemoteHarnessSecureHandshake, generation: Long) {
                rhCheck(generation == g && g == this@RemoteHarnessClient.generation, "stale-generation")
                socket?.send(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Handshake(payload), "native-${++controlID}", clock.epochMilliseconds(), limits))
                    ?: throw RemoteHarnessException("client-connection")
            }
            override fun sendRelay(payload: RemoteHarnessSecureRelay, generation: Long) {
                rhCheck(generation == g && g == this@RemoteHarnessClient.generation, "stale-generation")
                socket?.send(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Relay(payload), "native-${++controlID}", clock.epochMilliseconds(), limits))
                    ?: throw RemoteHarnessException("client-connection")
            }
            override fun retire(generation: Long) { if (generation == g) { socket?.close(); socket = null } }
        }
        val secure = RemoteHarnessSecureLink(packetPort, RemoteHarnessSecureNoiseFactory { _, _, _ ->
            r.useSeed { crypto.initiator(it, host.publicKey!!, info) }
        }, clock, object : RemoteHarnessSecureObserver {
            override fun authenticated(context: RemoteHarnessAuthenticatedContext) {
                if (g != generation) return
                this@RemoteHarnessClient.context = context; stage = "business"
                val business = RemoteHarnessCoordinator(link!!, clock, RemoteHarnessMutationJournal { command ->
                    rhCheck(knownCommands.size < 512 && command.logicalCommandID !in knownCommands, "client-bounds")
                    knownCommands.add(command.logicalCommandID)
                    try { persist(); true } catch (_: Exception) { block("The command could not be saved. Repair storage before sending."); false }
                })
                coordinator = business; business.beginConnection(context)
                business.describe { outcome -> if (g == generation) {
                    if (outcome.kind == RemoteHarnessOutcomeKind.RESULT) businessReady(g)
                    else fail("client-protocol")
                } }
            }
            override fun receivedBusinessBytes(bytes: ByteArray, context: RemoteHarnessAuthenticatedContext) {
                if (g == generation) coordinator?.receive(context, bytes)
            }
            override fun retired(context: RemoteHarnessAuthenticatedContext, reason: RemoteHarnessSecureRetirement) {
                if (g == generation) { coordinator?.disconnected(context); approvalActionEvidence.reset(null)
                    update(snapshot.copy(phase = RemoteHarnessClientPhase.DISCONNECTED, approvals = emptyList(), approvalActions = emptyMap(),
                    historyReady = false, status = RemoteSessionStatus.OUTCOME_UNKNOWN, error = "Computer disconnected. Reconnect to verify the latest session state.")) }
            }
        })
        link = secure
        secure.begin(authenticated, RemoteHarnessSecureEnrollment(RemoteHarnessSecureClientID(r.deviceID),
            RemoteHarnessSecureHostID(host.deviceID), object : RemoteHarnessSecureIdentity {}))
    }

    private fun businessReady(g: Long) {
        val c = coordinator ?: return
        c.open(RemoteHarnessOperations.workspaceFollow(), { notice -> if (g == generation && notice.kind == RemoteHarnessStreamNoticeKind.VALUE) {
            guardedSocket { receiveWorkspaces(notice.value ?: throw RemoteHarnessException("client-protocol")) }
        } }, { if (it.kind != RemoteHarnessOutcomeKind.RESULT) fail("client-protocol") })
        update(snapshot.copy(approvalSupported = c.approvalSupported()))
        if (snapshot.workspaceID == null) update(snapshot.copy(phase = RemoteHarnessClientPhase.WORKSPACES, status = RemoteSessionStatus.READY))
    }
    private fun openScopedBusiness(g: Long) {
        val c = coordinator ?: return
        if (snapshot.workspaceID != null && !scopedStarted) {
            val workspace = snapshot.workspaces.singleOrNull { it.id == snapshot.workspaceID } ?: throw RemoteHarnessException("client-history")
            rhCheck(snapshot.sessionID == null || snapshot.sessionID in workspace.sessionIDs, "client-history")
            scopedStarted = true
            update(snapshot.copy(phase = if (snapshot.sessionID == null) RemoteHarnessClientPhase.SESSIONS else RemoteHarnessClientPhase.SESSION,
                status = RemoteSessionStatus.READY))
            c.call(RemoteHarnessOperations.sessionList()) { outcome -> if (g == generation) guardedSocket {
                val items = array(requireResult(outcome).objectValue().rhRequired("items"))
                val allowed = snapshot.workspaces.firstOrNull { it.id == snapshot.workspaceID }?.sessionIDs?.toSet() ?: emptySet()
                val sessions = items.map { item -> val row = item.objectValue(); val id = row.rhString("sessionId").also(::rhID)
                    RemoteHarnessClientSession(id, sessionTitle(row) ?: id, row.rhRequired("running").booleanValue()) }.filter { it.id in allowed }
                update(snapshot.copy(sessions = sessions))
            } }
            c.call(RemoteHarnessOperations.modelCatalog()) { outcome -> if (g == generation) guardedSocket { receiveModels(requireResult(outcome)) } }
            if (snapshot.sessionID != null) {
                historyCursor = 0; pageCursor = null; historyThrough = 0; historyBytes = 0
                activeAttempt = null; attemptCommitted = false; attemptRevision = 0; attemptIndex = 0
                c.open(RemoteHarnessOperations.sessionFollow(snapshot.sessionID!!), { notice -> if (g == generation) guardedSocket {
                    if (notice.kind == RemoteHarnessStreamNoticeKind.VALUE) {
                        receiveHistory(notice.value ?: throw RemoteHarnessException("client-history")); refreshApprovalReadiness()
                    }
                    else update(snapshot.copy(historyReady = false, error = "Session stream closed. Reconnect to load its latest state."))
                } })
                c.open(RemoteHarnessOperations.sessionControl(), { notice -> if (g == generation && notice.kind == RemoteHarnessStreamNoticeKind.VALUE)
                    guardedSocket { receiveSessionControl(notice.value ?: throw RemoteHarnessException("client-history")) } })
                c.open(RemoteHarnessOperations.approvalEvents(), { notice -> if (g == generation) guardedSocket {
                    refreshApprovalReadiness(markAwaiting = true)
                } })
            }
        }
    }
    private fun receiveWorkspaces(value: RemoteHarnessJSON) {
        val p = value.objectValue()
        when (p.rhString("type")) {
            "baseline", "replace" -> {
                if (p.rhString("type") == "baseline") rhCheck(!workspaceBaseline, "client-protocol")
                val items = array(p.rhRequired("value").objectValue().rhRequired("items")).map(::workspace)
                rhCheck(items.map { it.id }.distinct().size == items.size, "client-protocol")
                workspaceBaseline = true; update(snapshot.copy(workspaces = items))
            }
            "upsert" -> { rhCheck(workspaceBaseline, "client-protocol"); val item = workspace(p.rhRequired("workspace"))
                update(snapshot.copy(workspaces = snapshot.workspaces.filter { it.id != item.id } + item)) }
            "remove" -> { rhCheck(workspaceBaseline, "client-protocol"); val id = p.rhString("workspaceId")
                update(snapshot.copy(workspaces = snapshot.workspaces.filter { it.id != id }))
                if (snapshot.workspaceID == id) throw RemoteHarnessException("client-history") }
            "order", "archived", "pinned" -> rhCheck(workspaceBaseline, "client-protocol")
            else -> throw RemoteHarnessException("client-protocol")
        }
        if (workspaceBaseline) openScopedBusiness(generation)
        if (snapshot.sessionID != null && snapshot.workspaces.none { it.id == snapshot.workspaceID && snapshot.sessionID in it.sessionIDs })
            throw RemoteHarnessException("client-history")
    }
    private fun workspace(value: RemoteHarnessJSON): RemoteHarnessClientWorkspace {
        val p = value.objectValue(); val id = p.rhString("workspaceId").also(::rhID)
        val sessions = array(p.rhRequired("sessionIds")).map { it.stringValue().also(::rhID) }
        return RemoteHarnessClientWorkspace(id, p.rhString("title"), p.rhString("path"), sessions)
    }
    fun chooseWorkspace(id: String) = action {
        val workspace = snapshot.workspaces.singleOrNull { it.id == id } ?: throw RemoteHarnessException("client-history")
        update(snapshot.copy(workspaceID = workspace.id, workspaceTitle = workspace.title, sessionID = null, timeline = emptyList(),
            sessions = emptyList(), historyReady = false)); persist(); connect()
    }
    fun chooseSession(id: String) = action {
        rhCheck(snapshot.sessions.any { it.id == id }, "client-history")
        openSession(id)
    }
    private fun openSession(id: String) {
        update(snapshot.copy(sessionID = id, timeline = emptyList(), historyReady = false)); persist(); connect()
    }
    fun createSession() = action {
        requireCompanion()
        val workspaceID = snapshot.workspaceID ?: throw RemoteHarnessException("client-history")
        val g = generation
        update(snapshot.copy(busy = true, error = null))
        coordinator!!.call(RemoteHarnessOperations.sessionCreate(workspaceID), identifier()) { outcome -> if (g == generation) guardedSocket {
            update(snapshot.copy(busy = false))
            val id = requireResult(outcome).objectValue().rhString("sessionId").also(::rhID)
            openSession(id)
        } }
    }
    private fun requireResult(outcome: RemoteHarnessOutcome): RemoteHarnessJSON {
        requireSuccess(outcome)
        return outcome.value ?: throw RemoteHarnessException("client-protocol")
    }
    private fun requireSuccess(outcome: RemoteHarnessOutcome) {
        if (outcome.kind == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN) {
            update(snapshot.copy(busy = false, status = RemoteSessionStatus.OUTCOME_UNKNOWN,
                error = "The command outcome is unknown. It will not be sent again. Reconnect to check the Host."))
            throw RemoteHarnessException("client-history")
        }
        rhCheck(outcome.kind in setOf(RemoteHarnessOutcomeKind.RESULT, RemoteHarnessOutcomeKind.MUTATION_RECEIPT, RemoteHarnessOutcomeKind.STOP_RECEIPT), "client-protocol")
    }
    private fun sessionTitle(p: Map<String, RemoteHarnessJSON>): String? = (p["projections"] as? RemoteHarnessJSON.ObjectValue)
        ?.values?.get("values")?.objectValue()?.get("title")?.let { if (it is RemoteHarnessJSON.StringValue) it.value else null }
    private fun receiveModels(value: RemoteHarnessJSON) {
        val p = value.objectValue()
        val models = array(p.rhRequired("groups")).flatMap { group -> val gp = group.objectValue(); val provider = gp.rhString("id")
            array(gp.rhRequired("models")).map { item -> val m = item.objectValue()
                val efforts = m["reasoning"]?.objectValue()?.get("efforts")?.let(::array)?.map { e ->
                    val effort = e.objectValue(); effort.rhString("id") to effort.rhString("name") } ?: emptyList()
                RemoteHarnessClientModel(provider, m.rhString("id"), m.rhString("name"), efforts) } }
        val selection = p.rhRequired("default").objectValue()
        update(snapshot.copy(models = models, provider = snapshot.provider ?: selection.rhString("provider"),
            model = snapshot.model ?: selection.rhString("model"), effort = snapshot.effort ?: selection["reasoningEffort"]?.stringValue()))
    }
    fun selectModel(provider: String, model: String, effort: String?) = action {
        requireCompanion()
        val selected = snapshot.models.singleOrNull { it.provider == provider && it.id == model } ?: throw RemoteHarnessException("client-protocol")
        rhCheck(effort == null || selected.efforts.any { it.first == effort }, "client-protocol")
        val session = snapshot.sessionID ?: throw RemoteHarnessException("client-history"); val g = generation
        update(snapshot.copy(busy = true))
        coordinator!!.call(RemoteHarnessOperations.selectModel(session, provider, model, effort), identifier()) { outcome -> if (g == generation) guardedSocket {
            val actual = requireResult(outcome).objectValue().rhRequired("selected").objectValue()
            update(snapshot.copy(busy = false, provider = actual.rhString("provider"), model = actual.rhString("model"),
                effort = actual["reasoningEffort"]?.stringValue())); persist()
        } }
    }
    fun send() = action {
        requireCompanion()
        rhCheck(snapshot.historyReady && snapshot.draft.isNotBlank() && snapshot.status != RemoteSessionStatus.OUTCOME_UNKNOWN, "client-history")
        val session = snapshot.sessionID ?: throw RemoteHarnessException("client-history")
        val text = snapshot.draft; val id = identifier(); val g = generation
        update(snapshot.copy(busy = true, error = null))
        coordinator!!.call(RemoteHarnessOperations.sessionPrompt(session, id, text, "UTC")) { outcome -> if (g == generation) guardedSocket {
            requireSuccess(outcome)
            update(snapshot.copy(busy = false, draft = if (snapshot.draft == text) "" else snapshot.draft,
                status = snapshot.status))
            append(RemoteHarnessClientTimelineItem("receipt-$id", "status", "Task received by computer.")); persist()
        } }
    }
    private fun requireCompanion() {
        rhCheck(coordinator?.isReady() == true, "client-history")
        rhCheck(snapshot.approvalSupported && coordinator?.approvalSupported() == true, "client-companion")
    }
    fun decideApproval(eventID: String, allowedOnce: Boolean) = action {
        val business = coordinator ?: throw RemoteHarnessException("client-history")
        val approval = business.pendingApprovals().singleOrNull { it.eventID == eventID } ?: throw RemoteHarnessException("approval-expired")
        rhCheck(snapshot.historyReady && approvalActionEvidence.resolve(approval, snapshot.sessionID) != null, "approval-action-unverified")
        val g = generation
        business.call(RemoteHarnessOperations.approval(approval, allowedOnce), identifier()) { outcome -> if (g == generation) guardedSocket {
            requireSuccess(outcome)
            update(snapshot.copy(status = if (snapshot.status == RemoteSessionStatus.AWAITING_APPROVAL) RemoteSessionStatus.RUNNING else snapshot.status,
                error = null)); refreshApprovalReadiness(); persist()
        } }
        refreshApprovalReadiness()
    }
    private fun refreshApprovalReadiness(markAwaiting: Boolean = false) {
        val approvals = coordinator?.pendingApprovals() ?: emptyList()
        update(snapshot.copy(approvals = approvals,
            approvalActions = if (snapshot.historyReady) approvalActionEvidence.resolved(approvals, snapshot.sessionID) else emptyMap(),
            status = if (markAwaiting && snapshot.status != RemoteSessionStatus.STOP_REQUESTED && approvals.isNotEmpty())
                RemoteSessionStatus.AWAITING_APPROVAL else snapshot.status))
    }
    fun stop() = action {
        if (snapshot.status == RemoteSessionStatus.STOP_REQUESTED) return@action
        val session = snapshot.sessionID ?: throw RemoteHarnessException("client-history"); val g = generation
        rhCheck(snapshot.historyReady, "client-history")
        update(snapshot.copy(status = RemoteSessionStatus.STOP_REQUESTED, error = null))
        coordinator!!.call(RemoteHarnessOperations.sessionCancel(session), identifier()) { outcome -> if (g == generation) guardedSocket {
            rhCheck(requireResult(outcome).objectValue().rhRequired("accepted").booleanValue(), "client-protocol")
            // Admission receipt never means that the remote Agent has stopped.
            persist()
        } }
    }
    fun earlierHistory() = action {
        val before = pageCursor ?: throw RemoteHarnessException("client-history")
        rhCheck(snapshot.historyReady && snapshot.hasMore && before > 0, "client-history")
        val session = snapshot.sessionID ?: throw RemoteHarnessException("client-history"); val g = generation
        update(snapshot.copy(busy = true))
        coordinator!!.call(RemoteHarnessOperations.sessionPage(session, historyThrough, before)) { outcome -> if (g == generation) guardedSocket {
            val result = requireResult(outcome).objectValue(); val records = array(result.rhRequired("records"))
            val previous = snapshot.timeline; update(snapshot.copy(timeline = emptyList()))
            records.forEach { historyRecord(it, historical = true) }
            val earlier = snapshot.timeline; update(snapshot.copy(timeline = (earlier + previous).distinctBy { it.id }.takeLast(512),
                hasMore = result.rhRequired("hasMore").booleanValue(), busy = false)); refreshApprovalReadiness(); persist()
        } }
    }
    private fun array(value: RemoteHarnessJSON): List<RemoteHarnessJSON> = (value as? RemoteHarnessJSON.ArrayValue)?.values
        ?: throw RemoteHarnessException("client-protocol")
    // The official empty JSONL session uses -1; transport counters remain unsigned.
    private fun sessionCursor(value: RemoteHarnessJSON): Long =
        if (value is RemoteHarnessJSON.NumberValue && value.token == "-1") -1 else value.integerValue()
    private fun receiveHistory(value: RemoteHarnessJSON) {
        val p = value.objectValue()
        when (p.rhString("type")) {
            "snapshot" -> {
                rhCheck(!snapshot.historyReady && p.rhRequired("header").objectValue().rhString("id") == snapshot.sessionID, "client-history")
                historyCursor = sessionCursor(p.rhRequired("cursor")); historyThrough = historyCursor
                approvalActionEvidence.reset(snapshot.sessionID)
                update(snapshot.copy(timeline = emptyList(), hasMore = p.rhRequired("hasMore").booleanValue()))
                array(p.rhRequired("records")).forEach { historyRecord(it, historical = true, snapshotRecord = true) }
                val stream = p["assistantStream"]?.objectValue()
                attemptRevision = stream?.get("revision")?.integerValue() ?: 0
                stream?.get("activeAttempt")?.objectValue()?.let { attempt ->
                    update(snapshot.copy(status = RemoteSessionStatus.RUNNING))
                    activeAttempt = attempt.rhString("attemptId").also(::rhID); attemptIndex = attempt.rhRequired("nextIndex").integerValue()
                    approvalActionEvidence.activeTurn(attempt.rhRequired("turn").integerValue(true))
                    rhCheck(sessionCursor(attempt.rhRequired("startedAfterSeq")) <= historyCursor, "client-history")
                    array(attempt.rhRequired("stream")).forEach { compactChunk(it) }
                }
                projections(p.rhRequired("projections"))
                update(snapshot.copy(historyReady = true, error = null)); persist()
            }
            "event" -> { rhCheck(snapshot.historyReady, "client-history"); historyRecord(value, historical = false); persist() }
            "assistant-stream" -> { rhCheck(snapshot.historyReady, "client-history"); assistantFrame(p.rhRequired("frame")); persist() }
            else -> throw RemoteHarnessException("client-history")
        }
    }
    private fun historyRecord(value: RemoteHarnessJSON, historical: Boolean, snapshotRecord: Boolean = false) {
        val root = value.objectValue(); rhCheck(root.rhString("type") == "event", "client-history")
        val event = root.rhRequired("event").objectValue(); val seq = event.rhRequired("seq").integerValue()
        if (!historical) { rhCheck(seq == historyCursor + 1, "client-history"); historyCursor = seq }
        else rhCheck(seq <= historyThrough, "client-history")
        pageCursor = pageCursor?.let { minOf(it, seq) } ?: seq
        val type = event.rhString("type"); val data = event.rhRequired("data").objectValue()
        val replace = event["surfaceOp"] as? RemoteHarnessJSON.ObjectValue
        if (replace != null) {
            rhCheck(replace.values.rhString("op") == "replace", "client-history")
            val start = replace.values.rhRequired("startSeq").integerValue(); val end = replace.values.rhRequired("endSeq").integerValue()
            rhCheck(start <= end, "client-history")
            // This accepted compatibility shape may remove a previously matched call. Invalidate
            // before publishing the replacement or indexing its new event; the capture uses append.
            approvalActionEvidence.historyReplaced()
            update(snapshot.copy(approvalActions = emptyMap(), timeline = snapshot.timeline.filter { item ->
                item.id.removePrefix("event-").toLongOrNull()?.let { it !in start..end } ?: true }))
        }
        approvalActionEvidence.observe(snapshot.sessionID, seq, type, data, advanceRun = !historical || snapshotRecord)
        when (type) {
            "user/message", "assistant/message", "tool/result" -> {
                val message = if (type == "user/message") data else data.rhRequired("message").objectValue()
                val content = array(message.rhRequired("content")); val text = StringBuilder(); val reasoning = StringBuilder()
                content.forEach { block -> val b = block.objectValue(); when (b.rhString("type")) {
                    "text" -> text.append(b.rhString("text"))
                    "reasoning" -> reasoning.append(b.rhString("text"))
                    "tool-call" -> text.append("\nTool: ").append(b["name"]?.stringValue() ?: "Requested tool")
                    else -> {} } }
                if (type == "assistant/message" && !historical) {
                    // Durable output precedes assistant-stream.end in the official runtime.
                    // Retire its display now, while retaining attempt/index validation until end.
                    clearLiveDisplay()
                    if (activeAttempt != null) attemptCommitted = true
                }
                append(RemoteHarnessClientTimelineItem("event-$seq", type.substringBefore('/'), text.toString(), reasoning.toString()))
            }
            "tool/call" -> {
                val name = (data["name"] as? RemoteHarnessJSON.StringValue)?.value
                val arguments = (data["arguments"] as? RemoteHarnessJSON.StringValue)?.value
                append(RemoteHarnessClientTimelineItem("event-$seq", "tool", if (name != null && arguments != null) "$name\n$arguments"
                    else "Tool call details could not be verified. Stop the task or inspect it on your computer."))
            }
            "turn/start" -> if (!historical) update(snapshot.copy(status = runningStatus()))
            "turn/end" -> if (!historical) {
                clearLiveAttempt()
                val reason = data.rhRequired("reason").objectValue().rhString("kind")
                update(snapshot.copy(status = if (reason == "aborted") RemoteSessionStatus.STOPPED else RemoteSessionStatus.READY))
                append(RemoteHarnessClientTimelineItem("event-$seq", "status", if (reason == "aborted") "Computer confirmed: stopped" else "Turn ended: $reason"))
            }
            "model/selection" -> { update(snapshot.copy(provider = data.rhString("provider"), model = data.rhString("model"), effort = data["reasoningEffort"]?.stringValue())) }
            else -> {} // Log-only Host events do not fabricate visible messages.
        }
    }
    private fun append(item: RemoteHarnessClientTimelineItem) {
        val next = snapshot.timeline.filter { it.id != item.id } + item
        historyBytes = next.sumOf { it.text.toByteArray().size + it.reasoning.toByteArray().size }
        rhCheck(next.size <= 512 && historyBytes <= 2_097_152, "client-bounds")
        update(snapshot.copy(timeline = next))
    }
    private fun clearLiveDisplay() {
        val id = activeAttempt ?: return
        update(snapshot.copy(timeline = snapshot.timeline.filter { it.id != "live-$id" && !it.id.startsWith("live-$id-tool-") }))
    }
    private fun clearLiveAttempt() {
        clearLiveDisplay(); activeAttempt = null; attemptCommitted = false
    }
    private fun runningStatus() = if (snapshot.status in setOf(RemoteSessionStatus.STOP_REQUESTED, RemoteSessionStatus.AWAITING_APPROVAL))
        snapshot.status else RemoteSessionStatus.RUNNING
    private fun assistantFrame(value: RemoteHarnessJSON) {
        val p = value.objectValue(); val type = p.rhString("type"); val id = p.rhString("attemptId").also(::rhID)
        val revision = p.rhRequired("revision").integerValue()
        if (type == "start") {
            rhCheck(revision > attemptRevision && activeAttempt == null &&
                sessionCursor(p.rhRequired("startedAfterSeq")) <= historyCursor, "client-history")
            activeAttempt = id; attemptCommitted = false; attemptRevision = revision; attemptIndex = 0
            update(snapshot.copy(status = runningStatus())); return
        }
        rhCheck(id == activeAttempt && revision > attemptRevision && p.rhRequired("index").integerValue() == attemptIndex, "client-history")
        attemptRevision = revision
        if (type == "chunk") {
            rhCheck(!attemptCommitted, "client-history")
            renderChunk(p.rhRequired("chunk")); attemptIndex++
        } else {
            rhCheck(type == "end", "client-history"); clearLiveAttempt()
        }
    }
    private fun compactChunk(value: RemoteHarnessJSON) {
        val p = value.objectValue()
        when (p.rhString("type")) {
            "text-chunks", "reasoning-chunks" -> {
                val type = if (p.rhString("type") == "text-chunks") "text-delta" else "reasoning-delta"
                array(p.rhRequired("texts")).forEach { renderChunk(obj("type" to str(type), "text" to it)) }
            }
            "chunk" -> renderChunk(p.rhRequired("chunk"))
            "tool-call-chunks" -> renderChunk(obj("type" to str("tool-call-delta"), "id" to p.rhRequired("id"),
                "name" to p["name"], "argumentsDelta" to str(array(p.rhRequired("args")).joinToString("") { it.stringValue() })))
        }
    }
    private fun renderChunk(value: RemoteHarnessJSON) {
        val p = value.objectValue(); val type = p.rhString("type"); val attempt = activeAttempt ?: throw RemoteHarnessException("client-history")
        if (type in setOf("text-delta", "reasoning-delta")) {
            val id = "live-$attempt"; val old = snapshot.timeline.firstOrNull { it.id == id } ?: RemoteHarnessClientTimelineItem(id, "assistant", "")
            append(if (type == "text-delta") old.copy(text = old.text + p.rhString("text")) else old.copy(reasoning = old.reasoning + p.rhString("text")))
        } else if (type == "tool-call-delta") {
            val id = "live-$attempt-tool-${p.rhString("id")}"; val old = snapshot.timeline.firstOrNull { it.id == id }
            append(RemoteHarnessClientTimelineItem(id, "tool", (old?.text ?: ((p["name"]?.stringValue() ?: "Tool") + "\n")) + (p["argumentsDelta"]?.stringValue() ?: "")))
        }
    }
    private fun receiveSessionControl(value: RemoteHarnessJSON) {
        val p = value.objectValue()
        when (p.rhString("type")) {
            "baseline" -> p.rhRequired("value").objectValue().rhRequired("projections").objectValue()[snapshot.sessionID]?.let(::projections)
            "projection" -> if (p.rhString("sessionId") == snapshot.sessionID) projection(p.rhString("key"), p.rhRequired("value"))
            else -> throw RemoteHarnessException("client-history")
        }
    }
    private fun projections(value: RemoteHarnessJSON) { value.objectValue().rhRequired("values").objectValue().forEach { (key, v) -> projection(key, v) } }
    private fun projection(key: String, value: RemoteHarnessJSON) {
        if (key == "modelSelection") {
            val p = value.objectValue(); val choice = p["next"].takeUnless { it === RemoteHarnessJSON.NullValue }
                ?: p["lastUsed"].takeUnless { it === RemoteHarnessJSON.NullValue }
            choice?.objectValue()?.let { update(snapshot.copy(provider = it.rhString("provider"), model = it.rhString("model"), effort = it["reasoningEffort"]?.stringValue())) }
        }
    }
    fun tick() {
        owner(); if (stage == "idle") return
        guardedSocket {
            val now = clock.monotonicMilliseconds()
            if (stage == "hello") rhCheck(now <= helloDeadline, "client-deadline")
            if (stage in setOf("opening", "hello", "accepting")) rhCheck(now <= setupDeadline, "client-deadline")
            link?.checkDeadlines(generation); coordinator?.expire(); socket?.checkDeadline(now)
            if (coordinator != null) refreshApprovalReadiness()
            if (pingNonce != null) rhCheck(now <= pingDeadline, "client-deadline")
            if (nextPing > 0 && now >= nextPing && pingNonce == null) {
                val nonce = identifier(); pingNonce = nonce; pingDeadline = now + 50_000; nextPing = now + 25_000
                sendControl("ping", obj("nonce" to str(nonce)))
            }
        }
    }
    fun disconnect() { owner(); disconnectInternal(); try { persist() } catch (_: Exception) { fail("client-storage") } }
    private fun disconnectInternal() {
        val hadConnection = stage != "idle"
        generation++; stage = "idle"; pingNonce = null; nextPing = 0
        val oldCoordinator = coordinator; coordinator = null
        val oldContext = context; context = null
        approvalActionEvidence.reset(null)
        if (oldContext != null) oldCoordinator?.disconnected(oldContext)
        link?.activeGeneration()?.let { link?.close(it) }; link = null; socket?.close(); socket = null
        if (hadConnection) update(snapshot.copy(phase = RemoteHarnessClientPhase.DISCONNECTED, busy = false, historyReady = false, approvals = emptyList(), approvalActions = emptyMap(),
            status = if (snapshot.status in setOf(RemoteSessionStatus.RUNNING, RemoteSessionStatus.STOP_REQUESTED) || snapshot.busy)
                RemoteSessionStatus.OUTCOME_UNKNOWN else RemoteSessionStatus.DISCONNECTED))
    }
    fun revokeDevice() = action {
        api.revoke(requireAccess()); disconnectInternal()
        update(snapshot.copy(error = "This device was revoked on the server. Sign in again only after the administrator restores access."))
    }
}
