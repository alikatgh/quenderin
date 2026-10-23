package ai.quenderin.core

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private fun secureReject(block: () -> Unit) {
    val failure = try { block(); null } catch (error: Exception) { error }
    check(failure is RemoteHarnessException && !failure.toString().contains("PRIVATE"))
}
private class SecureClock : RemoteHarnessClock {
    var now = 0L
    var onRead: (() -> Unit)? = null
    override fun epochMilliseconds() = 1L
    override fun monotonicMilliseconds(): Long { onRead?.invoke(); return now }
}
/** Deliberately NOT cryptography: deterministic plaintext plus a 16-byte marker. */
private class SecureNoise : RemoteHarnessSecureNoise {
    var complete = false; var sending = 0L; var receiving = 0L
    var sendAdvance = 1L; var receiveAdvance = 1L
    var decryptThrows = false; var encryptOversize = false
    var resultPayload = byteArrayOf(); var resultResponse: ByteArray? = null
    var onShutdown: (() -> Unit)? = null; var onEncrypt: (() -> Unit)? = null
    var onDecrypt: (() -> Unit)? = null; var onCounters: (() -> Unit)? = null
    var shutdowns = 0; var handshakeReads = 0
    val encrypted = arrayListOf<ByteArray>()
    override fun initiate(emptyPayload: ByteArray): ByteArray { check(emptyPayload.isEmpty()); return byteArrayOf(0x11) }
    override fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult {
        handshakeReads++
        check(bytes.contentEquals(byteArrayOf(0x22))); complete = true
        return RemoteHarnessSecureHandshakeResult(true, resultPayload, resultResponse)
    }
    override fun counters(): RemoteHarnessSecureCounters { onCounters?.invoke(); return RemoteHarnessSecureCounters(complete, sending, receiving) }
    override fun encrypt(plaintext: ByteArray): ByteArray {
        encrypted.add(plaintext.copyOf()); sending += sendAdvance; onEncrypt?.invoke()
        return if (encryptOversize) ByteArray(65_536) else plaintext + ByteArray(16)
    }
    override fun decrypt(ciphertext: ByteArray): ByteArray {
        onDecrypt?.invoke(); if (decryptThrows) error("PRIVATE tag failure")
        receiving += receiveAdvance; return ciphertext.copyOf(ciphertext.size - 16)
    }
    override fun shutdown() { shutdowns++; onShutdown?.invoke() }
}
private class SecureRig : RemoteHarnessSecurePacketPort, RemoteHarnessSecureNoiseFactory, RemoteHarnessSecureObserver {
    val clock = SecureClock()
    val enrollment = RemoteHarnessSecureEnrollment(RemoteHarnessSecureClientID("client-a"), RemoteHarnessSecureHostID("host-a"), object : RemoteHarnessSecureIdentity {})
    var info = RemoteHarnessSecureConnectionInfo("connection-a", "client-a", "host-a")
    val noises = arrayListOf<SecureNoise>()
    val sent = arrayListOf<RemoteHarnessSecureRelay>()
    val retired = arrayListOf<Long>(); val noticed = arrayListOf<Long>(); val received = arrayListOf<ByteArray>()
    var factoryCalls = 0; var handshakeSends = 0
    var expectedPrologue = "DSH-REMOTE\u0000v=1\u0000connection=connection-a\u0000host=host-a\u0000client=client-a"
    var onFactory: (() -> Unit)? = null; var onHandshake: ((Long) -> Unit)? = null
    var onSend: (() -> Unit)? = null; var onAuth: ((RemoteHarnessAuthenticatedContext) -> Unit)? = null
    var onReceive: (() -> Unit)? = null; var onRetire: (() -> Unit)? = null
    var onInfo: (() -> Unit)? = null; var onNoise: ((SecureNoise) -> Unit)? = null
    val link = RemoteHarnessSecureLink(this, this, clock, this)
    fun context(generation: Long = 1) = RemoteHarnessAuthenticatedContext(ConversationBinding.create("remote", ConnectionKind.REMOTE_HARNESS,
        "https://relay.example", "host-a", "a".repeat(64), "workspace-a"), "client-a", "connection-a", generation, "session-a")
    val noise: SecureNoise get() = noises.last()
    fun begin(generation: Long = 1) = link.begin(context(generation), enrollment)
    fun ready(generation: Long = 1) { begin(generation); step2(generation); check(link.isReady()) }
    fun step2(generation: Long = 1, step: Int = 2, target: String = "client-a") = link.receiveHandshake(
        RemoteHarnessSecureHandshake("connection-a", target, step, byteArrayOf(0x22)), generation)
    fun relay(plaintext: ByteArray, counter: Long = noise.receiving, generation: Long = 1, target: String = "client-a") = link.receiveRelay(
        RemoteHarnessSecureRelay("connection-a", target, counter, plaintext + ByteArray(16)), generation)
    override fun connectionInfo(): RemoteHarnessSecureConnectionInfo { onInfo?.invoke(); return info }
    override fun makeInitiator(enrollment: RemoteHarnessSecureEnrollment, info: RemoteHarnessSecureConnectionInfo,
        context: RemoteHarnessSecureNoiseContext): RemoteHarnessSecureNoise {
        factoryCalls++
        check(context.pattern == "Noise_IK_25519_ChaChaPoly_SHA256")
        check(context.prologue.contentEquals(expectedPrologue.toByteArray()))
        val noise = SecureNoise(); noises.add(noise); onNoise?.invoke(noise); onFactory?.invoke(); return noise
    }
    override fun sendHandshake(payload: RemoteHarnessSecureHandshake, generation: Long) {
        handshakeSends++; check(payload.step == 1 && payload.targetDeviceID == "host-a" && payload.bytes.contentEquals(byteArrayOf(0x11)))
        onHandshake?.invoke(generation)
    }
    override fun sendRelay(payload: RemoteHarnessSecureRelay, generation: Long) { sent.add(payload); onSend?.invoke() }
    override fun retire(generation: Long) { retired.add(generation); onRetire?.invoke() }
    override fun authenticated(context: RemoteHarnessAuthenticatedContext) { noticed.add(context.generation); onAuth?.invoke(context) }
    override fun receivedBusinessBytes(bytes: ByteArray, context: RemoteHarnessAuthenticatedContext) { received.add(bytes.copyOf()); onReceive?.invoke() }
    override fun retired(context: RemoteHarnessAuthenticatedContext, reason: RemoteHarnessSecureRetirement) {}
    fun gone() { check(link.activeGeneration() == null && !link.isReady() && link.queuedByteCount() == 0 && link.queuedMessageCount() == 0) }
}

/** Bounded watchdog stays outside both contenders; a lock regression cannot hang the verifier. */
private fun secureThreadConfinement() {
    val done = CountDownLatch(1); val failure = AtomicReference<Throwable?>()
    val owner = Thread {
        try {
            val f = SecureRig(); val outcomes = arrayListOf<RemoteHarnessOutcomeKind>()
            val coordinator = RemoteHarnessCoordinator(f.link, f.clock, RemoteHarnessMutationJournal { true })
            f.onAuth = { coordinator.beginConnection(it); coordinator.describe {} }
            f.onReceive = { coordinator.receive(f.context(), f.received.last()) }
            f.ready()
            val describe = RemoteHarnessCodec.decode(f.noise.encrypted.single())
            val response = "{\"v\":1,\"id\":\"owner-response\",\"type\":\"rpc.response\",\"timestamp\":1,\"payload\":{\"requestId\":\"${describe.id}\",\"result\":{\"capabilities\":[\"harness.remote.v3\"]}}}".toByteArray()
            f.relay(response); check(coordinator.isReady())
            val held = CountDownLatch(1); val attempt = CountDownLatch(1); val workerFailure = AtomicReference<Throwable?>()
            val worker = Thread {
                try {
                    synchronized(coordinator) {
                        held.countDown(); check(attempt.await(2, TimeUnit.SECONDS))
                        // With the old link monitor, owner->observer waits for this monitor
                        // while this call waits for the link: an actual ABBA cycle.
                        coordinator.call(RemoteHarnessOperations.sessionPrompt("session-a", "thread-command", "synthetic")) { outcomes.add(it.kind) }
                        val entries: List<() -> Unit> = listOf(
                            { f.link.send(f.context(), byteArrayOf(97)) }, { f.begin(2) }, { f.step2() }, { f.relay(byteArrayOf(97)) },
                            { f.link.checkDeadlines(1) }, { f.link.close(1) }, { f.link.invalidate(f.context()) }, { f.link.confirmRetired(1) },
                            { f.link.isReady(); Unit }, { f.link.activeGeneration(); Unit }, { f.link.queuedByteCount(); Unit },
                            { f.link.queuedMessageCount(); Unit }, { f.link.unconfirmedRetirementGeneration(); Unit })
                        for (entry in entries) {
                            val error = try { entry(); null } catch (error: RemoteHarnessException) { error }
                            check(error?.code == "secure-link-owner-thread")
                        }
                        check(f.link.toString() == "RemoteHarnessSecureLink(redacted)")
                    }
                } catch (error: Throwable) { workerFailure.set(error) }
            }
            worker.isDaemon = true; worker.start(); check(held.await(2, TimeUnit.SECONDS))
            f.onReceive = { attempt.countDown(); coordinator.receive(f.context(), f.received.last()) }
            f.relay(response)
            worker.join(2_000); check(!worker.isAlive && workerFailure.get() == null)
            check(outcomes == listOf(RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN) && f.sent.size == 1 && f.link.isReady())
        } catch (error: Throwable) { failure.set(error) } finally { done.countDown() }
    }
    owner.isDaemon = true; owner.start()
    check(done.await(5, TimeUnit.SECONDS) && failure.get() == null)
}

private fun secureScenario(action: String) {
    when (action) {
        "synchronous-step2-auth-send" -> {
            val f = SecureRig(); f.onHandshake = { f.step2(it) }
            f.onAuth = { check(f.link.isReady()); f.link.send(it, byteArrayOf(97)) }
            f.begin(); check(f.noticed == listOf(1L) && f.sent.single().counter == 0L && f.noise.sending == 1L)
        }
        "reentrant-fragment-order" -> {
            val f = SecureRig(); f.ready(); var once = false
            f.onSend = { if (!once) { once = true; f.link.send(f.context(), byteArrayOf(98)) } }
            f.link.send(f.context(), ByteArray(49_153) { 97 })
            check(f.sent.map { it.counter } == listOf(0L, 1L, 2L))
            check(f.noise.encrypted.map { it.size } == listOf(49_169, 18, 1))
            f.sent.forEach { f.relay(it.ciphertext.copyOf(it.ciphertext.size - 16)) }
            check(f.received.size == 2 && f.received[0].contentEquals(ByteArray(49_153) { 97 }) && f.received[1].contentEquals(byteArrayOf(98)))
            check(f.link.queuedMessageCount() == 0)
        }
        "partial-send-throws" -> {
            val f = SecureRig(); f.ready(); f.onSend = { error("PRIVATE accepted then throw") }
            secureReject { f.link.send(f.context(), ByteArray(49_153) { 97 }) }; f.gone()
            check(f.sent.size == 1 && f.retired == listOf(1L) && f.noise.shutdowns == 1)
        }
        "decrypt-fault-retires" -> {
            val f = SecureRig(); f.ready(); f.noise.decryptThrows = true
            secureReject { f.relay(byteArrayOf(97)) }; f.gone(); f.relay(byteArrayOf(98))
            check(f.received.isEmpty() && f.noise.shutdowns == 1 && f.retired == listOf(1L))
        }
        "handshake-deadline-boundary" -> {
            val valid = SecureRig(); valid.begin(); valid.clock.now = 9_999; valid.step2(); check(valid.link.isReady())
            val expired = SecureRig(); expired.begin(); expired.clock.now = 10_000
            secureReject { expired.step2() }; expired.gone(); check(expired.noticed.isEmpty())
            val idle = SecureRig(); idle.begin(); idle.clock.now = 10_000
            secureReject { idle.link.checkDeadlines(1) }; idle.gone()
        }
        "identity-preflight" -> {
            val f = SecureRig(); f.info = RemoteHarnessSecureConnectionInfo("connection-a", "client-a", "wrong-host")
            secureReject { f.begin() }; f.gone(); check(f.factoryCalls == 0 && f.handshakeSends == 0)
            val other = SecureRig()
            secureReject { other.link.begin(other.context().copy(callerDeviceID = "wrong-client"), other.enrollment) }
            check(other.factoryCalls == 0)
        }
        "identifier-validation" -> {
            for (bad in listOf("", "a\u0000b", "a".repeat(1_025), "界".repeat(342), "\uD800")) {
                secureReject { RemoteHarnessSecureClientID(bad) }; secureReject { RemoteHarnessSecureHostID(bad) }
                secureReject { RemoteHarnessSecureConnectionInfo(bad, "client", "host") }
            }
            check(RemoteHarnessSecureClientID("界".repeat(341)).value.toByteArray().size == 1_023)
            val oversized = ByteArray(65_536)
            secureReject { RemoteHarnessSecureHandshake("c", "t", 2, oversized) }
            secureReject { RemoteHarnessSecureRelay("c", "t", 0, oversized) }
            secureReject { RemoteHarnessSecureHandshakeResult(true, oversized) }
            secureReject { RemoteHarnessSecureHandshakeResult(true, byteArrayOf(), oversized) }
        }
        "handshake-step-target-duplicate" -> {
            for (step in listOf(1, 3)) { val f = SecureRig(); f.begin(); secureReject { f.step2(step = step) }; f.gone() }
            val f = SecureRig(); f.begin(); secureReject { f.step2(target = "host-a") }; f.gone()
            val duplicate = SecureRig(); duplicate.ready(); secureReject { duplicate.step2() }; duplicate.gone()
        }
        "packet-binding-counter" -> {
            for (counter in listOf(-1L, 1L, 9_007_199_254_740_992L)) {
                val f = SecureRig(); f.ready(); secureReject { f.relay(byteArrayOf(97), counter) }; f.gone(); check(f.received.isEmpty())
            }
            val f = SecureRig(); f.ready(); secureReject { f.relay(byteArrayOf(97), target = "host-a") }; f.gone()
        }
        "provider-counter-state" -> {
            for (advance in listOf(0L, 2L, -1L)) {
                val f = SecureRig(); f.ready(); f.noise.sendAdvance = advance
                secureReject { f.link.send(f.context(), byteArrayOf(97)) }; f.gone(); check(f.sent.isEmpty())
                val g = SecureRig(); g.ready(); g.noise.receiveAdvance = advance
                secureReject { g.relay(byteArrayOf(97)) }; g.gone(); check(g.received.isEmpty())
            }
            for (counter in listOf(-1L, 9_007_199_254_740_992L)) {
                val f = SecureRig(); f.onNoise = { it.sending = counter }; secureReject { f.begin() }; f.gone()
            }
            val f = SecureRig(); f.ready(); f.noise.complete = false
            secureReject { f.link.send(f.context(), byteArrayOf(97)) }; f.gone()
            val preRead = SecureRig(); preRead.begin(); preRead.noise.complete = true
            secureReject { preRead.step2() }; preRead.gone(); check(preRead.noise.handshakeReads == 0)
        }
        "handshake-payload-response" -> {
            for (response in listOf(false, true)) {
                val f = SecureRig(); f.onNoise = { if (response) it.resultResponse = byteArrayOf() else it.resultPayload = byteArrayOf(97) }
                f.begin(); secureReject { f.step2() }; f.gone(); check(f.noticed.isEmpty())
            }
        }
        "fragment-expiry-idle" -> {
            val frames = RemoteHarnessFragments(1).encode(ByteArray(49_153) { 97 }, 1)
            val f = SecureRig(); f.ready(); f.relay(frames[0].data); f.clock.now = 119_999; f.link.checkDeadlines(1)
            check(f.received.isEmpty()); f.clock.now = 120_000
            secureReject { f.link.checkDeadlines(1) }; f.gone()
        }
        "fragment-error-retires" -> {
            val f = SecureRig(); f.ready(); secureReject { f.relay(byteArrayOf(0x44, 0x53, 0x48, 0x46)) }; f.gone()
            check(f.received.isEmpty() && f.retired == listOf(1L))
        }
        "queue-message-budget" -> {
            val f = SecureRig(); f.ready(); var once = false
            f.onSend = { if (!once) { once = true
                repeat(255) { f.link.send(f.context(), byteArrayOf()) }
                check(f.link.queuedMessageCount() == 256)
                secureReject { f.link.send(f.context(), byteArrayOf()) }
            } }
            secureReject { f.link.send(f.context(), byteArrayOf(97)) }; f.gone(); check(f.sent.size == 1)
        }
        "queue-byte-budget" -> {
            val f = SecureRig(); f.ready(); var once = false
            f.onSend = { if (!once) { once = true; f.link.send(f.context(), ByteArray(4_194_304) { 98 })
                check(f.link.queuedByteCount() == 8_388_608); secureReject { f.link.send(f.context(), byteArrayOf(99)) }
            } }
            secureReject { f.link.send(f.context(), ByteArray(4_194_304) { 97 }) }; f.gone(); check(f.sent.size == 1)
        }
        "stale-callbacks-after-replacement" -> {
            val f = SecureRig(); f.ready(); f.ready(2)
            f.step2(1); f.relay(byteArrayOf(97), generation = 1); f.link.checkDeadlines(1); f.link.close(1); f.link.invalidate(f.context())
            secureReject { f.link.send(f.context(), byteArrayOf(97)) }; secureReject { f.begin(1) }
            check(f.link.activeGeneration() == 2L && f.link.isReady() && f.received.isEmpty() && f.retired == listOf(1L))
        }
        "replacement-during-factory" -> {
            val f = SecureRig(); var once = false; f.onFactory = { if (!once) { once = true; f.ready(2) } }
            secureReject { f.begin() }; check(f.link.activeGeneration() == 2L && f.link.isReady() && f.noises[0].shutdowns == 1 && f.retired == listOf(1L))
        }
        "replacement-during-clock-info" -> {
            for (useClock in listOf(false, true)) {
                val f = SecureRig(); var once = false
                val callback = { if (!once) { once = true; f.ready(2) }; Unit }
                if (useClock) f.clock.onRead = callback else f.onInfo = callback
                secureReject { f.begin() }; check(f.link.activeGeneration() == 2L && f.link.isReady() && f.retired == listOf(1L))
            }
        }
        "replacement-during-shutdown" -> {
            val f = SecureRig(); f.ready(); f.noise.onShutdown = { secureReject { f.begin(3) } }
            f.ready(2); check(f.link.activeGeneration() == 2L && f.link.isReady() && f.retired == listOf(1L))
            secureReject { f.begin(2) }; check(f.link.activeGeneration() == 2L)
        }
        "replacement-during-observers" -> {
            val f = SecureRig(); f.onAuth = { if (it.generation == 1L) f.ready(2) }
            secureReject { f.ready() }; check(f.link.activeGeneration() == 2L && f.link.isReady())
            val g = SecureRig(); g.ready(); g.onReceive = { g.ready(2) }
            secureReject { g.relay(byteArrayOf(97)) }; check(g.link.activeGeneration() == 2L && g.link.isReady() && g.received.size == 1)
        }
        "replacement-during-encrypt-send" -> {
            for (inNoise in listOf(false, true)) {
                val f = SecureRig(); f.ready()
                if (inNoise) f.noise.onEncrypt = { f.ready(2) } else f.onSend = { f.onSend = null; f.ready(2) }
                secureReject { f.link.send(f.context(), ByteArray(49_153) { 97 }) }
                check(f.link.activeGeneration() == 2L && f.link.isReady() && f.sent.size == if (inNoise) 0 else 1)
            }
        }
        "observer-and-cleanup-failure" -> {
            val f = SecureRig(); f.onAuth = { error("PRIVATE observer") }; f.begin(); secureReject { f.step2() }; f.gone()
            val g = SecureRig(); g.ready(); g.onReceive = { error("PRIVATE receive observer") }; secureReject { g.relay(byteArrayOf(97)) }; g.gone()
            val h = SecureRig(); h.ready(); h.noise.onShutdown = { error("PRIVATE shutdown") }; h.onRetire = { error("PRIVATE retire") }
            h.link.close(1); h.link.close(1); h.gone(); check(h.retired == listOf(1L) && h.noise.shutdowns == 1)
            check(h.link.unconfirmedRetirementGeneration() == 1L); secureReject { h.begin(2) }
            h.link.confirmRetired(2); check(h.link.unconfirmedRetirementGeneration() == 1L)
            h.link.confirmRetired(1); h.onRetire = null; h.ready(2); check(h.link.isReady())
            h.onRetire = { error("PRIVATE second retirement") }; h.link.close(2)
            h.link.confirmRetired(1); check(h.link.unconfirmedRetirementGeneration() == 2L)
            secureReject { h.begin(3) }
            val replacement = SecureRig(); replacement.ready()
            replacement.onRetire = { secureReject { replacement.begin(3) }; error("PRIVATE replacement cleanup") }
            secureReject { replacement.begin(2) }; replacement.gone()
            check(replacement.link.unconfirmedRetirementGeneration() == 1L && replacement.factoryCalls == 1)
            replacement.link.confirmRetired(1); replacement.onRetire = null
            secureReject { replacement.begin(2) }; replacement.ready(3); check(replacement.link.isReady())
        }
        "clock-regression-overflow" -> {
            val f = SecureRig(); f.clock.now = 10; f.ready(); f.clock.now = 9
            secureReject { f.link.checkDeadlines(1) }; f.gone()
            val g = SecureRig(); g.clock.now = Long.MAX_VALUE - 9_999
            secureReject { g.begin() }; g.gone(); check(g.handshakeSends == 0 && g.noise.shutdowns == 1)
        }
        "ciphertext-size-and-reentrant-decrypt" -> {
            val f = SecureRig(); f.ready(); f.noise.encryptOversize = true
            secureReject { f.link.send(f.context(), byteArrayOf(97)) }; f.gone(); check(f.sent.isEmpty())
            val g = SecureRig(); g.ready(); g.noise.onDecrypt = { g.noise.onDecrypt = null; g.relay(byteArrayOf(98)) }
            secureReject { g.relay(byteArrayOf(97)) }; g.gone(); check(g.received.isEmpty())
        }
        "privacy-and-byte-ownership" -> {
            val f = SecureRig(); f.ready(); val bytes = byteArrayOf(97); val p = RemoteHarnessSecureRelay("PRIVATE", "PRIVATE", 0, bytes)
            bytes[0] = 98; val exported = p.ciphertext; exported[0] = 99; check(p.ciphertext[0] == 97.toByte())
            for (v in listOf(f.link, f.info, f.enrollment, f.enrollment.client, f.enrollment.host, p,
                RemoteHarnessSecureHandshake("PRIVATE", "PRIVATE", 2, bytes), RemoteHarnessSecureHandshakeResult(true, bytes))) {
                check(v.toString().contains("redacted") && !v.toString().contains("PRIVATE"))
            }
        }
        "opaque-unicode-identities" -> {
            val f = SecureRig(); f.info = RemoteHarnessSecureConnectionInfo("connection-a", "clie\u0301nt", "host-a")
            val enrolled = RemoteHarnessSecureEnrollment(RemoteHarnessSecureClientID("cli\u00e9nt"), f.enrollment.host, f.enrollment.identity)
            secureReject { f.link.begin(f.context().copy(callerDeviceID = "cli\u00e9nt"), enrolled) }; check(f.factoryCalls == 0)
            for (targetMismatch in listOf(false, true)) {
                val g = SecureRig(); g.info = RemoteHarnessSecureConnectionInfo("caf\u00e9", "cli\u00e9nt", "host-a")
                g.expectedPrologue = "DSH-REMOTE\u0000v=1\u0000connection=caf\u00e9\u0000host=host-a\u0000client=cli\u00e9nt"
                val enrollment = RemoteHarnessSecureEnrollment(RemoteHarnessSecureClientID("cli\u00e9nt"), g.enrollment.host, g.enrollment.identity)
                val context = g.context().copy(connectionID = "caf\u00e9", callerDeviceID = "cli\u00e9nt")
                g.link.begin(context, enrollment)
                g.link.receiveHandshake(RemoteHarnessSecureHandshake("caf\u00e9", "cli\u00e9nt", 2, byteArrayOf(0x22)), 1)
                check(g.link.isReady())
                secureReject { g.link.receiveRelay(RemoteHarnessSecureRelay(if (targetMismatch) "caf\u00e9" else "cafe\u0301",
                    if (targetMismatch) "clie\u0301nt" else "cli\u00e9nt", 0, ByteArray(17)), 1) }
                g.gone(); check(g.received.isEmpty())
            }
            val binding = SecureRig(); val exact = binding.context().copy(sessionID = "caf\u00e9")
            binding.link.begin(exact, binding.enrollment); binding.step2()
            val different = exact.copy(sessionID = "cafe\u0301")
            secureReject { binding.link.send(different, byteArrayOf(97)) }; binding.link.invalidate(different)
            check(binding.link.isReady() && binding.retired.isEmpty())
        }
        "serialized-owner-confinement" -> secureThreadConfinement()
        "coordinator-roundtrip-unknown" -> {
            val f = SecureRig(); val prepared = arrayListOf<RemoteHarnessPreparedMutation>(); val outcomes = arrayListOf<RemoteHarnessOutcomeKind>()
            val coordinator = RemoteHarnessCoordinator(f.link, f.clock, RemoteHarnessMutationJournal { prepared.add(it); true })
            f.onAuth = { coordinator.beginConnection(it); coordinator.describe { result -> outcomes.add(result.kind) } }
            f.onReceive = { coordinator.receive(f.context(), f.received.last()) }
            f.ready()
            val describe = RemoteHarnessCodec.decode(f.noise.encrypted.single())
            val response = "{\"v\":1,\"id\":\"host-response\",\"type\":\"rpc.response\",\"timestamp\":1,\"payload\":{\"requestId\":\"${describe.id}\",\"result\":{\"capabilities\":[\"harness.remote.v3\"]}}}"
            f.relay(response.toByteArray()); check(coordinator.isReady() && outcomes == listOf(RemoteHarnessOutcomeKind.RESULT))
            f.onSend = { error("PRIVATE accepted then throw") }
            coordinator.call(RemoteHarnessOperations.sessionPrompt("session-a", "command-a", "synthetic")) { outcomes.add(it.kind) }
            check(prepared.size == 1 && outcomes.last() == RemoteHarnessOutcomeKind.OUTCOME_UNKNOWN && coordinator.pendingCount() == 0)
            f.gone(); check(f.sent.size == 2)
        }
        else -> error("unsupported secure-link fixture")
    }
}

/** Source-only injected-provider scenarios. Markers prove assertions, never crypto/network interop. */
fun main(args: Array<String>) {
    check(args.size == 1)
    val file = File(args[0]); check(file.length() in 1..65_536)
    val root = RemoteHarnessJSON.parse(file.readText()).objectValue()
    check(root.rhRequired("schemaVersion").integerValue() == 1L && root.rhString("upstreamRevision") == RemoteHarnessCodec.UPSTREAM_REVISION)
    val seen = hashSetOf<String>()
    for (value in (root.rhRequired("cases") as RemoteHarnessJSON.ArrayValue).values) {
        val fixture = value.objectValue(); val id = fixture.rhString("id"); check(seen.add(id))
        try {
            val steps = (fixture.rhRequired("steps") as RemoteHarnessJSON.ArrayValue).values; check(steps.isNotEmpty())
            for (step in steps) secureScenario(step.objectValue().rhString("action"))
        } catch (_: Throwable) { error("Remote Harness secure-link fixture failed: $id") }
        println("REMOTE_HARNESS_SECURE_LINK_FIXTURE_PASS $id")
    }
    check(seen.isNotEmpty())
}
