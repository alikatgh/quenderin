package ai.quenderin.remote.crypto

import ai.quenderin.core.*
import java.security.SecureRandom
import kotlin.system.exitProcess

// Host-only integration: actual generated UniFFI/Rust Noise, production owners,
// and explicitly test-only enrollment, packet transport and in-memory journal.
// This does not establish account enrollment, network delivery or Host execution.
private const val CONNECTION = "linked-synthetic-connection"
private const val CLIENT = "linked-synthetic-client"
private const val HOST = "linked-synthetic-host"
private const val SESSION = "linked-synthetic-session"
private const val COMMAND = "linked-synthetic-command"
private const val GENERATION = 1L
private val prompt = "synthetic-linked-prompt-" + "p".repeat(61_440)
private val padding = "synthetic-linked-padding-" + "s".repeat(55_000)

private class TestIdentity(val privateKey: ByteArray, val peerPublicKey: ByteArray) : RemoteHarnessSecureIdentity

private class LinkedNoise(private var handle: NoiseIkSession?) : RemoteHarnessSecureNoise {
    var shutdowns = 0; private set
    var disposed = false; private set
    var atShutdown: NoiseCounters? = null; private set
    private fun live() = checkNotNull(handle)
    override fun initiate(emptyPayload: ByteArray): ByteArray {
        check(emptyPayload.isEmpty())
        return live().initiate()
    }
    override fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult {
        val read = live().readHandshake(bytes)
        return RemoteHarnessSecureHandshakeResult(read.complete, byteArrayOf(), read.response)
    }
    override fun counters(): RemoteHarnessSecureCounters {
        val counters = live().counters()
        // Check the unsigned generated representation BEFORE any signed conversion.
        check(counters.sending <= RemoteHarnessSecureLink.MAX_COUNTER.toULong() &&
            counters.receiving <= RemoteHarnessSecureLink.MAX_COUNTER.toULong())
        return RemoteHarnessSecureCounters(counters.complete, counters.sending.toLong(), counters.receiving.toLong())
    }
    override fun encrypt(plaintext: ByteArray) = live().encrypt(plaintext)
    override fun decrypt(ciphertext: ByteArray) = live().decrypt(ciphertext)
    override fun shutdown() {
        val current = handle ?: return
        handle = null; shutdowns++
        try {
            atShutdown = try { current.counters() } catch (_: NoiseException) { null }
            current.shutdown()
        } finally {
            // Rust shutdown and generated-wrapper disposal are distinct operations.
            current.close()
            disposed = current.uniffiIsDestroyed
        }
    }
}

private enum class Mode { ROUND_TRIP, HANDSHAKE_TAMPER, TAG_TAMPER }

private class LinkedRig(private val mode: Mode) : AutoCloseable, RemoteHarnessSecurePacketPort, RemoteHarnessSecureObserver {
    private val random = SecureRandom()
    private val clientPrivate = ByteArray(32).also(random::nextBytes)
    private val hostPrivate = ByteArray(32).also(random::nextBytes)
    private val identity = TestIdentity(clientPrivate, derivePublicKey(hostPrivate))
    private val responder = NoiseIkSession.create(NoiseRole.RESPONDER, hostPrivate, derivePublicKey(clientPrivate), CONNECTION, HOST, CLIENT)
    private val enrollment = RemoteHarnessSecureEnrollment(RemoteHarnessSecureClientID(CLIENT), RemoteHarnessSecureHostID(HOST), identity)
    val context = RemoteHarnessAuthenticatedContext(ConversationBinding.create("linked-synthetic-profile", ConnectionKind.REMOTE_HARNESS,
        "https://synthetic.invalid", HOST, "ab".repeat(32), "linked-synthetic-workspace"), CLIENT, CONNECTION, GENERATION, SESSION)
    private val peerFragments = RemoteHarnessFragments(GENERATION)
    private val expectedInbound = java.util.ArrayDeque<ByteArray>()
    private val clock = object : RemoteHarnessClock {
        override fun epochMilliseconds() = 1L
        override fun monotonicMilliseconds() = 0L
    }
    var factoryCalls = 0; private set
    lateinit var adapter: LinkedNoise; private set
    private val factory = RemoteHarnessSecureNoiseFactory { enrolled, info, noiseContext ->
        check(enrolled.identity === identity && info.connectionID == CONNECTION && info.localDeviceID == CLIENT && info.remoteDeviceID == HOST)
        check(noiseContext.pattern == "Noise_IK_25519_ChaChaPoly_SHA256")
        check(noiseContext.prologue.contentEquals("DSH-REMOTE\u0000v=1\u0000connection=$CONNECTION\u0000host=$HOST\u0000client=$CLIENT".encodeToByteArray()))
        factoryCalls++
        LinkedNoise(NoiseIkSession.create(NoiseRole.INITIATOR, identity.privateKey, identity.peerPublicKey,
            info.connectionID, info.remoteDeviceID, info.localDeviceID)).also { adapter = it }
    }
    val link = RemoteHarnessSecureLink(this, factory, clock, this)
    // Deliberately memory-only: proves prepare-before-send ordering, not durability.
    val prepared = arrayListOf<RemoteHarnessPreparedMutation>()
    val coordinator = RemoteHarnessCoordinator(link, clock, RemoteHarnessMutationJournal {
        check(prepared.isEmpty() && it.logicalCommandID == COMMAND && it.context == context)
        prepared.add(it); true
    })
    var authenticatedCount = 0; private set
    var businessCount = 0; private set
    var outboundBusinessCount = 0; private set
    var outgoingFrames = 0; private set
    var incomingFrames = 0; private set
    var retiredCount = 0; private set
    private var retiredPackets = 0
    private var responderDisposed = false
    private var responderAtRetirement: NoiseCounters? = null
    private val outcomes = arrayListOf<RemoteHarnessOutcome>()
    private var describeID: String? = null
    private var promptID: String? = null
    private var expectedOutgoingFrames = 0
    private var expectedIncomingFrames = 0
    private var tamperQueued = false
    private fun fragmentsFor(bytes: ByteArray) = maxOf(1, (bytes.size + RemoteHarnessFragments.CHUNK_BYTES - 1) / RemoteHarnessFragments.CHUNK_BYTES)
    private fun promptOperation() = RemoteHarnessOperations.sessionPrompt(SESSION, COMMAND, prompt)

    private var wireFrames = 0
    private fun wireHandshake(original: RemoteHarnessSecureHandshake): RemoteHarnessSecureHandshake {
        val id = "linked-synthetic-wire-${++wireFrames}"
        val envelope = RemoteHarnessControlWire.decode(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Handshake(original), id, 1))
        check(envelope.id == id && envelope.timestamp == 1L)
        val decoded = (envelope.packet as RemoteHarnessControlPacket.Handshake).value
        check(decoded.connectionID == original.connectionID && decoded.targetDeviceID == original.targetDeviceID &&
            decoded.step == original.step && decoded.bytes.contentEquals(original.bytes))
        return decoded
    }
    private fun wireRelay(original: RemoteHarnessSecureRelay): RemoteHarnessSecureRelay {
        val id = "linked-synthetic-wire-${++wireFrames}"
        val envelope = RemoteHarnessControlWire.decode(RemoteHarnessControlWire.encode(RemoteHarnessControlPacket.Relay(original), id, 1))
        check(envelope.id == id && envelope.timestamp == 1L)
        val decoded = (envelope.packet as RemoteHarnessControlPacket.Relay).value
        check(decoded.connectionID == original.connectionID && decoded.targetDeviceID == original.targetDeviceID &&
            decoded.counter == original.counter && decoded.ciphertext.contentEquals(original.ciphertext))
        return decoded
    }
    override fun connectionInfo() = RemoteHarnessSecureConnectionInfo(CONNECTION, CLIENT, HOST)
    override fun sendHandshake(payload: RemoteHarnessSecureHandshake, generation: Long) {
        val payload = wireHandshake(payload)
        check(generation == GENERATION && payload.step == 1 && payload.connectionID == CONNECTION && payload.targetDeviceID == HOST && payload.bytes.size == 96)
        val read = responder.readHandshake(payload.bytes)
        val reply = checkNotNull(read.response)
        check(read.complete && reply.size == 48)
        if (mode == Mode.HANDSHAKE_TAMPER) reply[reply.lastIndex] = (reply.last().toInt() xor 1).toByte()
        // Intentionally synchronous, exercising readiness reservation before send.
        link.receiveHandshake(wireHandshake(RemoteHarnessSecureHandshake(CONNECTION, CLIENT, 2, reply)), generation)
    }
    override fun sendRelay(payload: RemoteHarnessSecureRelay, generation: Long) {
        val payload = wireRelay(payload)
        check(generation == GENERATION && payload.connectionID == CONNECTION && payload.targetDeviceID == HOST && payload.counter == outgoingFrames.toLong())
        check(outgoingFrames < 8 && payload.ciphertext.size in 16..RemoteHarnessSecureLink.CIPHERTEXT_BYTES)
        outgoingFrames++
        val bytes = peerFragments.decode(responder.decrypt(payload.ciphertext), generation, 0)?.data
        if (mode == Mode.TAG_TAMPER) {
            check(bytes == null && peerFragments.assemblyCount == 1 && outgoingFrames == 1)
            link.send(context, expectedPromptBytes("queued-synthetic-rpc"))
            check(link.queuedMessageCount() == 2 && link.queuedByteCount() > 2 * RemoteHarnessFragments.CHUNK_BYTES)
            tamperQueued = true
            val fragment = peerFragments.encode(describeResponse("synthetic-rpc"), GENERATION).first().data
            val bad = responder.encrypt(fragment)
            bad[bad.lastIndex] = (bad.last().toInt() xor 1).toByte()
            link.receiveRelay(wireRelay(RemoteHarnessSecureRelay(CONNECTION, CLIENT, 0, bad)), generation)
            error("Tampered tag was accepted")
        }
        if (bytes == null) return
        check(mode == Mode.ROUND_TRIP && outboundBusinessCount < 2)
        val frame = RemoteHarnessCodec.decode(bytes)
        check(frame.type == "rpc.request" && frame.timestamp == 1L)
        val expected = if (outboundBusinessCount == 0) {
            check(frame.payload.values["method"]?.stringValue() == RemoteHarnessCodec.DESCRIBE && prepared.isEmpty())
            RemoteHarnessCodec.request(RemoteHarnessCodec.DESCRIBE, RemoteHarnessJSON.obj(), frame.id, 1).rawJSON.encodeToByteArray()
        } else {
            check(prepared.size == 1 && prepared.single().wireRequestID == frame.id)
            expectedPromptBytes(frame.id)
        }
        check(bytes.contentEquals(expected))
        expectedOutgoingFrames += fragmentsFor(expected)
        outboundBusinessCount++
        sendResponse(if (outboundBusinessCount == 1) describeResponse(frame.id) else receiptResponse(frame.id))
    }
    private fun expectedPromptBytes(id: String) = RemoteHarnessCodec.request(RemoteHarnessCodec.CALL, promptOperation().params(), id, 1).rawJSON.encodeToByteArray()
    private fun describeResponse(id: String) = ("{\"v\":1,\"id\":\"synthetic-describe-response\",\"type\":\"rpc.response\",\"timestamp\":1," +
        "\"payload\":{\"requestId\":\"$id\",\"result\":{\"capabilities\":[\"harness.remote.v3\"],\"syntheticPadding\":\"$padding\",\"syntheticNumber\":1.2300e+02}}}").encodeToByteArray()
    private fun receiptResponse(id: String) = ("{\"v\":1,\"id\":\"synthetic-prompt-response\",\"type\":\"rpc.response\",\"timestamp\":1," +
        "\"payload\":{\"requestId\":\"$id\",\"result\":{\"ok\":true,\"value\":{\"syntheticReceipt\":\"received\"}}}}").encodeToByteArray()
    private fun sendResponse(bytes: ByteArray) {
        check(expectedInbound.isEmpty())
        expectedInbound.add(bytes)
        val fragments = peerFragments.encode(bytes, GENERATION)
        check(fragments.size == fragmentsFor(bytes))
        expectedIncomingFrames += fragments.size
        for (fragment in fragments) {
            check(incomingFrames < 8)
            val counter = responder.counters().sending
            check(counter == incomingFrames.toULong())
            val ciphertext = responder.encrypt(fragment.data)
            incomingFrames++
            link.receiveRelay(wireRelay(RemoteHarnessSecureRelay(CONNECTION, CLIENT, counter.toLong(), ciphertext)), GENERATION)
        }
    }
    override fun authenticated(context: RemoteHarnessAuthenticatedContext) {
        check(context == this.context && link.isReady())
        authenticatedCount++
        check(authenticatedCount == 1)
        if (mode == Mode.ROUND_TRIP) {
            coordinator.beginConnection(context)
            describeID = coordinator.describe { outcomes.add(it) }
        }
    }
    override fun receivedBusinessBytes(bytes: ByteArray, context: RemoteHarnessAuthenticatedContext) {
        check(context == this.context && businessCount < 2 && bytes.contentEquals(expectedInbound.removeFirst()))
        businessCount++
        check(coordinator.receive(context, bytes))
    }
    override fun retire(generation: Long) {
        check(generation == GENERATION && retiredPackets == 0)
        retiredPackets++
        peerFragments.retire(generation); expectedInbound.clear()
        responderAtRetirement = try { responder.counters() } catch (_: NoiseException) { null }
        try { responder.shutdown() } finally { responder.close(); responderDisposed = responder.uniffiIsDestroyed }
    }
    override fun retired(context: RemoteHarnessAuthenticatedContext, reason: RemoteHarnessSecureRetirement) {
        check(context == this.context)
        retiredCount++
        coordinator.disconnected(context)
    }
    private fun gone() {
        check(!link.isReady() && link.activeGeneration() == null && link.queuedByteCount() == 0 && link.queuedMessageCount() == 0)
        check(link.unconfirmedRetirementGeneration() == null && coordinator.pendingCount() == 0 && coordinator.streamCount() == 0 && coordinator.hostSlotCount() == 0)
        check(retiredCount == 1 && retiredPackets == 1 && adapter.shutdowns == 1 && adapter.disposed && responderDisposed)
        check(peerFragments.isRetired && peerFragments.assemblyCount == 0 && peerFragments.declaredByteCount == 0 && expectedInbound.isEmpty())
    }
    fun run() {
        if (mode == Mode.HANDSHAKE_TAMPER) {
            reject { link.begin(context, enrollment) }
            gone(); check(authenticatedCount == 0 && businessCount == 0 && outgoingFrames == 0)
            return
        }
        link.begin(context, enrollment)
        check(factoryCalls == 1 && authenticatedCount == 1 && link.isReady())
        if (mode == Mode.TAG_TAMPER) {
            reject { link.send(context, expectedPromptBytes("synthetic-rpc")) }
            gone(); check(tamperQueued && businessCount == 0 && outboundBusinessCount == 0)
            check(adapter.atShutdown == NoiseCounters(true, 1uL, 0uL))
            check(responderAtRetirement == NoiseCounters(true, 1uL, 1uL))
            return
        }
        check(coordinator.isReady() && outcomes.size == 1 && outcomes.single().kind == RemoteHarnessOutcomeKind.RESULT && outcomes.single().wireRequestID == describeID)
        check(outcomes.single().value!!.objectValue()["syntheticPadding"]!!.stringValue() == padding)
        check((outcomes.single().value!!.objectValue()["syntheticNumber"] as RemoteHarnessJSON.NumberValue).token == "1.2300e+02")
        promptID = coordinator.call(promptOperation()) { outcomes.add(it) }
        check(prepared.size == 1 && outcomes.size == 2 && outcomes.last().kind == RemoteHarnessOutcomeKind.MUTATION_RECEIPT && outcomes.last().wireRequestID == promptID && outcomes.last().logicalCommandID == COMMAND)
        check(outcomes.last().value!!.objectValue()["syntheticReceipt"]!!.stringValue() == "received")
        check(outboundBusinessCount == 2 && businessCount == 2 && outgoingFrames == expectedOutgoingFrames && incomingFrames == expectedIncomingFrames)
        check(outgoingFrames > 1 && incomingFrames > 1)
        check(adapter.counters().let { it.complete && it.sending == outgoingFrames.toLong() && it.receiving == incomingFrames.toLong() })
        check(responder.counters() == NoiseCounters(true, incomingFrames.toULong(), outgoingFrames.toULong()))
        check(link.queuedByteCount() == 0 && link.queuedMessageCount() == 0 && coordinator.pendingCount() == 0 && expectedInbound.isEmpty())
        link.close(GENERATION); gone()
    }
    override fun close() {
        try { link.close(GENERATION) } finally {
            try { if (!responderDisposed) { responder.shutdown(); responder.close() } } finally {
                clientPrivate.fill(0); hostPrivate.fill(0); identity.peerPublicKey.fill(0)
            }
        }
    }
}

private fun reject(action: () -> Unit) {
    try { action() } catch (_: RemoteHarnessException) { return }
    error("Expected owner rejection")
}

fun main() {
    try {
        for (mode in Mode.entries) LinkedRig(mode).use { it.run() }
        println("NATIVE_LINKED_HARNESS_PASS kotlin")
    } catch (_: Throwable) {
        System.err.println("Native linked Kotlin harness failed.")
        exitProcess(1)
    }
}
