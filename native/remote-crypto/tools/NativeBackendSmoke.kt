package ai.quenderin.remote.crypto

import ai.quenderin.core.*
import java.security.SecureRandom

private fun failure(expected: RemoteHarnessCryptoFailure, action: () -> Unit) {
    try { action() } catch (error: RemoteHarnessCryptoException) {
        check(error.failure == expected); return
    }
    error("Expected fixed backend failure")
}

fun main() {
    val random = SecureRandom()
    val local = ByteArray(32).also(random::nextBytes)
    val remote = ByteArray(32).also(random::nextBytes)
    val backend = RemoteHarnessCryptoBackends.native()
    check(backend.isAvailable)
    val info = RemoteHarnessSecureConnectionInfo("backend-synthetic", "backend-client", "backend-host")
    failure(RemoteHarnessCryptoFailure.INVALID_KEY) { backend.publicKey(ByteArray(31)) }
    failure(RemoteHarnessCryptoFailure.INVALID_KEY) { backend.initiator(local, ByteArray(31), info) }
    val client = backend.initiator(local, derivePublicKey(remote), info)
    NoiseIkSession.create(NoiseRole.RESPONDER, remote, backend.publicKey(local), info.connectionID, info.remoteDeviceID, info.localDeviceID).use { host ->
        try {
            failure(RemoteHarnessCryptoFailure.INVALID_MESSAGE) { client.initiate(byteArrayOf(1)) }
            val hello = client.initiate(byteArrayOf())
            check(hello.size == 96)
            val reply = host.readHandshake(hello)
            check(reply.complete)
            val complete = client.readHandshake(checkNotNull(reply.response))
            check(complete.complete && complete.payload.isEmpty() && complete.response == null)
            val request = "synthetic backend request".encodeToByteArray()
            check(host.decrypt(client.encrypt(request)).contentEquals(request))
            val response = host.encrypt("synthetic backend answer".encodeToByteArray())
            val tampered = response.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
            failure(RemoteHarnessCryptoFailure.AUTHENTICATION) { client.decrypt(tampered) }
            check(client.counters().receiving == 0L)
            check(client.decrypt(response).contentEquals("synthetic backend answer".encodeToByteArray()))
            check(client.counters().sending == 1L && client.counters().receiving == 1L)
            client.shutdown(); client.shutdown()
            failure(RemoteHarnessCryptoFailure.CLOSED) { client.counters() }
        } finally { client.shutdown(); host.shutdown() }
    }
    local.fill(0); remote.fill(0)
    println("NATIVE_PRODUCTION_BACKEND_PASS kotlin")
}
