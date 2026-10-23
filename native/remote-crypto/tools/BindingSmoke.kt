package ai.quenderin.remote.crypto

import java.security.SecureRandom

// Compiles together with the actual generated source, then calls the exact
// locked Rust host library through JNA. No fake binding or crypto implementation.
private inline fun <reified T : Throwable> expectFailure(action: () -> Unit) {
    try {
        action()
    } catch (failure: Throwable) {
        check(failure is T) { "Unexpected binding error type" }
        return
    }
    error("Expected binding error was not returned")
}

private fun create(
    role: NoiseRole,
    privateKey: ByteArray,
    peer: ByteArray,
    connection: String = "host-binding-connection",
): NoiseIkSession = NoiseIkSession.create(
    role, privateKey, peer, connection, "host-binding-host", "host-binding-client",
)

private fun roundTripAndLifecycle(firstPrivate: ByteArray, secondPrivate: ByteArray) {
    val firstPublic = derivePublicKey(firstPrivate)
    val secondPublic = derivePublicKey(secondPrivate)
    check(firstPublic.size == 32 && secondPublic.size == 32) { "Invalid derived public length" }
    expectFailure<NoiseException.InvalidKey> { derivePublicKey(ByteArray(31)) }
    create(NoiseRole.INITIATOR, firstPrivate, secondPublic).use { initiator ->
        create(NoiseRole.RESPONDER, secondPrivate, firstPublic).use { responder ->
            expectFailure<NoiseException.InvalidState> { initiator.encrypt(byteArrayOf()) }
            val first = initiator.initiate()
            check(first.size == 96) { "Initiator handshake is not empty" }
            val reply = responder.readHandshake(first)
            val second = checkNotNull(reply.response) { "Missing responder handshake" }
            check(reply.complete && second.size == 48) { "Responder handshake is not empty" }
            val finished = initiator.readHandshake(second)
            check(finished.complete && finished.response == null) { "Handshake did not finish" }
            check(initiator.counters() == NoiseCounters(true, 0uL, 0uL)) { "Initiator initial counters differ" }
            check(responder.counters() == NoiseCounters(true, 0uL, 0uL)) { "Responder initial counters differ" }

            val plaintext = "host binding request".encodeToByteArray()
            val firstCiphertext = initiator.encrypt(plaintext)
            val tampered = firstCiphertext.copyOf()
            tampered[0] = (tampered[0].toInt() xor 1).toByte()
            expectFailure<NoiseException.AuthenticationFailed> { responder.decrypt(tampered) }
            check(responder.counters().receiving == 0uL) { "Tamper advanced receiving counter" }
            check(responder.decrypt(firstCiphertext).contentEquals(plaintext)) { "First transport differs" }
            expectFailure<NoiseException.AuthenticationFailed> { responder.decrypt(firstCiphertext) }
            check(responder.counters().receiving == 1uL) { "Replay advanced receiving counter" }
            val following = "next host binding request".encodeToByteArray()
            check(responder.decrypt(initiator.encrypt(following)).contentEquals(following)) { "Valid frame after replay failed" }
            val answer = "host binding answer".encodeToByteArray()
            check(initiator.decrypt(responder.encrypt(answer)).contentEquals(answer)) { "Reverse transport differs" }
            check(initiator.counters() == NoiseCounters(true, 2uL, 1uL)) { "Initiator final counters differ" }
            check(responder.counters() == NoiseCounters(true, 1uL, 2uL)) { "Responder final counters differ" }
            initiator.shutdown()
            initiator.shutdown()
            expectFailure<NoiseException.Closed> { initiator.counters() }
            expectFailure<NoiseException.Closed> { initiator.encrypt(byteArrayOf()) }
            responder.shutdown()
            expectFailure<NoiseException.Closed> { responder.decrypt(firstCiphertext) }
        }
    }
    val disposed = create(NoiseRole.INITIATOR, firstPrivate, secondPublic)
    disposed.shutdown()
    disposed.close()
    disposed.close()
    check(disposed.uniffiIsDestroyed) { "Generated wrapper did not release its handle" }
    expectFailure<IllegalStateException> { disposed.counters() }
}

private fun rejectsPeerAndContext(firstPrivate: ByteArray, secondPrivate: ByteArray, wrongPrivate: ByteArray) {
    val firstPublic = derivePublicKey(firstPrivate)
    val secondPublic = derivePublicKey(secondPrivate)
    val wrongPublic = derivePublicKey(wrongPrivate)
    create(NoiseRole.INITIATOR, firstPrivate, secondPublic).use { initiator ->
        create(NoiseRole.RESPONDER, secondPrivate, wrongPublic).use { responder ->
            expectFailure<NoiseException.PeerIdentityMismatch> { responder.readHandshake(initiator.initiate()) }
            expectFailure<NoiseException.Closed> { responder.counters() }
        }
    }
    create(NoiseRole.INITIATOR, firstPrivate, secondPublic).use { initiator ->
        create(NoiseRole.RESPONDER, secondPrivate, firstPublic, "other-host-binding-context").use { responder ->
            expectFailure<NoiseException.AuthenticationFailed> { responder.readHandshake(initiator.initiate()) }
            expectFailure<NoiseException.Closed> { responder.counters() }
        }
    }
}

fun main() {
    val random = SecureRandom()
    val firstPrivate = ByteArray(32).also(random::nextBytes)
    val secondPrivate = ByteArray(32).also(random::nextBytes)
    val wrongPrivate = ByteArray(32).also(random::nextBytes)
    try {
        roundTripAndLifecycle(firstPrivate, secondPrivate)
        rejectsPeerAndContext(firstPrivate, secondPrivate, wrongPrivate)
        println("QUENDERIN_REMOTE_KOTLIN_BINDING_SMOKE_PASS")
    } finally {
        firstPrivate.fill(0)
        secondPrivate.fill(0)
        wrongPrivate.fill(0)
    }
}
