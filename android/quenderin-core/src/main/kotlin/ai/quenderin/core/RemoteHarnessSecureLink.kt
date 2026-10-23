package ai.quenderin.core

private fun secureID(value: String) {
    rhCheck(value.isNotEmpty() && value.length <= 1_024 && '\u0000' !in value && value.toByteArray(Charsets.UTF_8).size <= 1_024,
        "secure-link-identity")
    var i = 0
    while (i < value.length) {
        val c = value[i++]
        if (c.isHighSurrogate()) { rhCheck(i < value.length && value[i].isLowSurrogate(), "secure-link-identity"); i++ }
        else rhCheck(!c.isLowSurrogate(), "secure-link-identity")
    }
}

class RemoteHarnessSecureClientID(val value: String) {
    init { secureID(value) }
    override fun toString() = "RemoteHarnessSecureClientID(redacted)"
}
class RemoteHarnessSecureHostID(val value: String) {
    init { secureID(value) }
    override fun toString() = "RemoteHarnessSecureHostID(redacted)"
}
class RemoteHarnessSecureConnectionInfo(val connectionID: String, val localDeviceID: String, val remoteDeviceID: String) {
    init { secureID(connectionID); secureID(localDeviceID); secureID(remoteDeviceID) }
    override fun toString() = "RemoteHarnessSecureConnectionInfo(redacted)"
}
/** Opaque reference to already trusted identity/key material; this API has no key export. */
interface RemoteHarnessSecureIdentity
/** Caller must first verify account membership, Host role, pin and durable enrollment.
 * Constructing this context is NOT evidence that those checks occurred. */
class RemoteHarnessSecureEnrollment(val client: RemoteHarnessSecureClientID, val host: RemoteHarnessSecureHostID,
    val identity: RemoteHarnessSecureIdentity) {
    override fun toString() = "RemoteHarnessSecureEnrollment(redacted)"
}
class RemoteHarnessSecureNoiseContext internal constructor(info: RemoteHarnessSecureConnectionInfo) {
    val pattern = "Noise_IK_25519_ChaChaPoly_SHA256"
    private val storage = "DSH-REMOTE\u0000v=1\u0000connection=${info.connectionID}\u0000host=${info.remoteDeviceID}\u0000client=${info.localDeviceID}".toByteArray(Charsets.UTF_8)
    val prologue: ByteArray get() = storage.copyOf()
    override fun toString() = "RemoteHarnessSecureNoiseContext(redacted)"
}
class RemoteHarnessSecureHandshake(val connectionID: String, val targetDeviceID: String, val step: Int, bytes: ByteArray) {
    init { secureID(connectionID); secureID(targetDeviceID); rhCheck(bytes.size <= 65_535, "secure-link-limit") }
    private val storage = bytes.copyOf()
    val bytes: ByteArray get() = storage.copyOf()
    override fun toString() = "RemoteHarnessSecureHandshake(redacted)"
}
class RemoteHarnessSecureRelay(val connectionID: String, val targetDeviceID: String, val counter: Long, ciphertext: ByteArray) {
    init { secureID(connectionID); secureID(targetDeviceID); rhCheck(ciphertext.size <= 65_535, "secure-link-limit") }
    private val storage = ciphertext.copyOf()
    val ciphertext: ByteArray get() = storage.copyOf()
    override fun toString() = "RemoteHarnessSecureRelay(redacted)"
}
class RemoteHarnessSecureHandshakeResult(val complete: Boolean, payload: ByteArray, response: ByteArray? = null) {
    init { rhCheck(payload.size <= 65_535 && (response == null || response.size <= 65_535), "secure-link-limit") }
    private val payloadStorage = payload.copyOf()
    private val responseStorage = response?.copyOf()
    val payload: ByteArray get() = payloadStorage.copyOf()
    val response: ByteArray? get() = responseStorage?.copyOf()
    override fun toString() = "RemoteHarnessSecureHandshakeResult(redacted)"
}
class RemoteHarnessSecureCounters(val complete: Boolean, val sending: Long, val receiving: Long) {
    override fun toString() = "RemoteHarnessSecureCounters(redacted)"
}
interface RemoteHarnessSecureNoise {
    fun initiate(emptyPayload: ByteArray): ByteArray
    fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult
    fun counters(): RemoteHarnessSecureCounters
    fun encrypt(plaintext: ByteArray): ByteArray
    fun decrypt(ciphertext: ByteArray): ByteArray
    fun shutdown()
}
fun interface RemoteHarnessSecureNoiseFactory {
    fun makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo,
        context: RemoteHarnessSecureNoiseContext): RemoteHarnessSecureNoise
}
/** Decoded-byte seam only. A future JSON/WSS adapter owns canonical unpadded Base64URL,
 * 64 KiB control / 1 MiB relay JSON bounds, account authentication and network I/O.
 * Every callback MUST retain the generation supplied here, including retirement. */
interface RemoteHarnessSecurePacketPort {
    fun connectionInfo(): RemoteHarnessSecureConnectionInfo
    fun sendHandshake(payload: RemoteHarnessSecureHandshake, generation: Long)
    fun sendRelay(payload: RemoteHarnessSecureRelay, generation: Long)
    fun retire(generation: Long)
}
enum class RemoteHarnessSecureRetirement { CLOSED, REPLACED, HANDSHAKE, DEADLINE, CLOCK, COUNTER, RECEIVE, SEND, LIMIT, OBSERVER }
interface RemoteHarnessSecureObserver {
    fun authenticated(context: RemoteHarnessAuthenticatedContext)
    fun receivedBusinessBytes(bytes: ByteArray, context: RemoteHarnessAuthenticatedContext)
    fun retired(context: RemoteHarnessAuthenticatedContext, reason: RemoteHarnessSecureRetirement)
}

/** Source-only owner; no crypto implementation, real authentication, scheduler, retries or reconnect.
 * Constructor thread is the enforced serialized owner. Packet adapter, coordinator and all callbacks
 * MUST dispatch to that same thread. There is no owner monitor held across coordinator callbacks.
 * Caller MUST drive checkDeadlines during idle periods with the original generation. */
class RemoteHarnessSecureLink(private val port: RemoteHarnessSecurePacketPort,
    private val factory: RemoteHarnessSecureNoiseFactory, private val clock: RemoteHarnessClock,
    private val observer: RemoteHarnessSecureObserver) : RemoteHarnessDecryptedPort {
    companion object {
        const val HANDSHAKE_MS = 10_000L
        const val QUEUE_BYTES = 8_388_608
        const val QUEUE_MESSAGES = 256
        const val CIPHERTEXT_BYTES = 65_535
        const val MAX_COUNTER = 9_007_199_254_740_991L
    }
    private enum class Phase { PREPARING, WAITING, READING, READY }
    private class Session(val context: RemoteHarnessAuthenticatedContext, val enrollment: RemoteHarnessSecureEnrollment) {
        var info: RemoteHarnessSecureConnectionInfo? = null
        var noise: RemoteHarnessSecureNoise? = null
        val fragments = RemoteHarnessFragments(context.generation)
        var phase = Phase.PREPARING
        var lastNow: Long? = null
        var deadline: Long? = null
        var sending = 0L
        var receiving = 0L
        var reading = false
        var draining = false
        val queue = java.util.ArrayDeque<ByteArray>()
        var reservedBytes = 0
        var reservedMessages = 0
    }
    private var session: Session? = null
    private val ownerThread = Thread.currentThread()
    private var maximumGeneration = 0L
    private var teardownPending: Long? = null
    private var retiring = false
    override fun toString() = "RemoteHarnessSecureLink(redacted)"
    fun isReady(): Boolean { owner(); return session?.phase == Phase.READY }
    fun activeGeneration(): Long? { owner(); return session?.context?.generation }
    fun queuedByteCount(): Int { owner(); return session?.reservedBytes ?: 0 }
    fun queuedMessageCount(): Int { owner(); return session?.reservedMessages ?: 0 }
    fun unconfirmedRetirementGeneration(): Long? { owner(); return teardownPending }

    fun begin(context: RemoteHarnessAuthenticatedContext, enrollment: RemoteHarnessSecureEnrollment) {
        owner()
        requireSecure(teardownPending == null, "teardown-unconfirmed")
        requireSecure(context.generation > maximumGeneration, "generation")
        maximumGeneration = context.generation // Reserve BEFORE old shutdown/observer callbacks.
        session?.let { retire(it, RemoteHarnessSecureRetirement.REPLACED) }
        requireSecure(maximumGeneration == context.generation && session == null && teardownPending == null, "generation")
        val s = Session(context, enrollment); session = s
        guarded(s, RemoteHarnessSecureRetirement.HANDSHAKE) {
            val info = external(s) { port.connectionInfo() }; s.info = info
            requireSecure(info.localDeviceID == enrollment.client.value && info.remoteDeviceID == enrollment.host.value &&
                context.callerDeviceID == enrollment.client.value && context.binding.hostID == enrollment.host.value &&
                context.connectionID == info.connectionID, "identity")
            // If the factory reenters/replaces, shut down its orphan result without touching the replacement.
            val noise = factory.makeInitiator(enrollment, info, RemoteHarnessSecureNoiseContext(info))
            if (session !== s) { try { noise.shutdown() } catch (_: Exception) {}; changed() }
            s.noise = noise
            counters(s, false)
            val now = now(s)
            requireSecure(now <= Long.MAX_VALUE - HANDSHAKE_MS, "clock")
            s.deadline = now + HANDSHAKE_MS
            val step1 = external(s) { noise.initiate(byteArrayOf()) }
            requireSecure(step1.size in 1..CIPHERTEXT_BYTES, "handshake")
            counters(s, false)
            checkTime(s)
            s.phase = Phase.WAITING // Reserve before wire: step2 may arrive synchronously.
            external(s) { port.sendHandshake(RemoteHarnessSecureHandshake(info.connectionID, info.remoteDeviceID, 1, step1), context.generation) }
        }
    }
    fun receiveHandshake(payload: RemoteHarnessSecureHandshake, generation: Long) {
        owner()
        val s = session?.takeIf { it.context.generation == generation } ?: return
        guarded(s, RemoteHarnessSecureRetirement.HANDSHAKE) {
            checkTime(s)
            val info = s.info
            requireSecure(s.phase == Phase.WAITING && info != null && payload.step == 2 &&
                payload.connectionID == info.connectionID && payload.targetDeviceID == info.localDeviceID &&
                payload.bytes.size in 1..CIPHERTEXT_BYTES, "handshake")
            s.phase = Phase.READING
            counters(s, false)
            val result = external(s) { s.noise!!.readHandshake(payload.bytes) }
            requireSecure(result.complete && result.response == null && result.payload.isEmpty(), "handshake")
            counters(s, true); checkTime(s)
            s.phase = Phase.READY; s.deadline = null // Observer may send immediately.
            guarded(s, RemoteHarnessSecureRetirement.OBSERVER) { external(s) { observer.authenticated(s.context) } }
        }
    }
    override fun send(context: RemoteHarnessAuthenticatedContext, frame: ByteArray) {
        owner()
        val s = session ?: changed()
        requireSecure(s.context == context, "binding") // Stale callers cannot retire the replacement.
        guarded(s, RemoteHarnessSecureRetirement.SEND) {
            requireSecure(s.phase == Phase.READY, "not-ready")
            requireSecure(frame.size <= RemoteHarnessFragments.MESSAGE_BYTES && s.reservedMessages < QUEUE_MESSAGES &&
                frame.size <= QUEUE_BYTES - s.reservedBytes, "limit")
            s.reservedMessages++; s.reservedBytes += frame.size; s.queue.add(frame.copyOf())
            if (!s.draining) drain(s)
        }
    }
    private fun drain(s: Session) {
        s.draining = true
        while (s.queue.isNotEmpty()) {
            val message = s.queue.removeFirst() // Reservation includes this active batch.
            for (frame in s.fragments.encode(message, s.context.generation)) {
                checkTime(s); counters(s, true)
                requireSecure(s.sending < MAX_COUNTER, "counter")
                val counter = s.sending
                val ciphertext = external(s) { s.noise!!.encrypt(frame.data) }
                requireSecure(ciphertext.size in 16..CIPHERTEXT_BYTES, "ciphertext")
                s.sending = counter + 1; counters(s, true)
                val info = s.info!!
                external(s) { port.sendRelay(RemoteHarnessSecureRelay(info.connectionID, info.remoteDeviceID, counter, ciphertext), s.context.generation) }
            }
            s.reservedBytes -= message.size; s.reservedMessages--
        }
        s.draining = false
    }
    fun receiveRelay(payload: RemoteHarnessSecureRelay, generation: Long) {
        owner()
        val s = session?.takeIf { it.context.generation == generation } ?: return
        guarded(s, RemoteHarnessSecureRetirement.RECEIVE) {
            requireSecure(s.phase == Phase.READY && !s.reading, "not-ready")
            s.reading = true // Reserve before clock/provider callbacks.
            checkTime(s)
            val info = s.info!!
            requireSecure(payload.connectionID == info.connectionID && payload.targetDeviceID == info.localDeviceID &&
                payload.counter in 0..MAX_COUNTER && payload.counter == s.receiving && s.receiving < MAX_COUNTER &&
                payload.ciphertext.size in 16..CIPHERTEXT_BYTES, "packet")
            counters(s, true)
            val counter = s.receiving
            val plaintext = external(s) { s.noise!!.decrypt(payload.ciphertext) }
            s.receiving = counter + 1; counters(s, true)
            val now = now(s)
            val message = s.fragments.decode(plaintext, s.context.generation, now)
            s.reading = false
            if (message != null) guarded(s, RemoteHarnessSecureRetirement.OBSERVER) {
                external(s) { observer.receivedBusinessBytes(message.data, s.context) }
            }
        }
    }
    /** Generation required: an old timer/close must never address a replacement. */
    fun checkDeadlines(generation: Long) {
        owner()
        val s = session?.takeIf { it.context.generation == generation } ?: return
        guarded(s, RemoteHarnessSecureRetirement.DEADLINE) { checkTime(s) }
    }
    fun close(generation: Long) {
        owner()
        session?.takeIf { it.context.generation == generation }?.let { retire(it, RemoteHarnessSecureRetirement.CLOSED) }
    }
    override fun invalidate(context: RemoteHarnessAuthenticatedContext) {
        owner()
        session?.takeIf { it.context == context }?.let { retire(it, RemoteHarnessSecureRetirement.CLOSED) }
    }
    /** Trusted adapter confirmation ONLY after this exact generation's channel and Host
     * reservations are actually gone. This does not retry, reconnect or infer cleanup. */
    fun confirmRetired(generation: Long) {
        owner()
        if (!retiring && teardownPending == generation) teardownPending = null
    }
    private fun now(s: Session): Long {
        val value = external(s) { clock.monotonicMilliseconds() }
        requireSecure(value >= 0 && (s.lastNow == null || value >= s.lastNow!!), "clock")
        s.lastNow = value; return value
    }
    private fun checkTime(s: Session) {
        val value = now(s)
        requireSecure(s.deadline == null || value < s.deadline!!, "deadline")
        s.fragments.checkExpiry(s.context.generation, value)
    }
    private fun counters(s: Session, complete: Boolean) {
        val c = external(s) { s.noise!!.counters() }
        requireSecure(c.complete == complete && c.sending in 0..MAX_COUNTER && c.receiving in 0..MAX_COUNTER &&
            c.sending == s.sending && c.receiving == s.receiving, "counter")
    }
    private fun <T> external(s: Session, block: () -> T): T {
        val value = block(); if (session !== s) changed(); return value
    }
    private fun guarded(s: Session, reason: RemoteHarnessSecureRetirement, block: () -> Unit) {
        try { block() } catch (_: Exception) {
            retire(s, reason)
            // No injected diagnostic, cause, credential or payload is propagated.
            throw RemoteHarnessException("secure-link-failed")
        }
    }
    private fun retire(s: Session, reason: RemoteHarnessSecureRetirement) {
        if (session !== s) return
        session = null; s.queue.clear(); s.reservedBytes = 0; s.reservedMessages = 0
        teardownPending = s.context.generation; retiring = true
        s.fragments.retire(s.context.generation)
        val noise = s.noise; s.noise = null
        // State is gone BEFORE callbacks. Cleanup always addresses this exact generation;
        // reentrant replacement never prevents the remaining old-generation cleanup.
        try { noise?.shutdown() } catch (_: Exception) {}
        try { port.retire(s.context.generation); if (teardownPending == s.context.generation) teardownPending = null } catch (_: Exception) {}
        retiring = false
        try { observer.retired(s.context, reason) } catch (_: Exception) {}
    }
    private fun requireSecure(value: Boolean, code: String) { if (!value) throw RemoteHarnessException("secure-link-$code") }
    private fun owner() { requireSecure(Thread.currentThread() === ownerThread, "owner-thread") }
    private fun changed(): Nothing = throw RemoteHarnessException("secure-link-generation")
}
