package ai.quenderin.remote.crypto

import ai.quenderin.core.*

/** Uses the generated UniFFI contract, never a handwritten cryptographic implementation. */
class NativeRemoteHarnessCryptoBackend : RemoteHarnessCryptoBackend {
    init { uniffiEnsureInitialized() }
    override val isAvailable = true
    override fun publicKey(privateSeed: ByteArray): ByteArray {
        validateKeys(privateSeed)
        return sanitized { derivePublicKey(privateSeed) }
    }
    override fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo): RemoteHarnessSecureNoise {
        validateKeys(privateSeed, peerPublicKey)
        return sanitized { NativeRemoteHarnessNoise(NoiseIkSession.create(NoiseRole.INITIATOR, privateSeed, peerPublicKey,
            info.connectionID, info.remoteDeviceID, info.localDeviceID)) }
    }
    private fun validateKeys(vararg keys: ByteArray) {
        if (keys.any { it.size != 32 }) throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.INVALID_KEY)
    }
}

private inline fun <T> sanitized(action: () -> T): T = try { action() } catch (error: NoiseException) {
    throw RemoteHarnessCryptoException(when (error) {
        is NoiseException.InvalidKey -> RemoteHarnessCryptoFailure.INVALID_KEY
        is NoiseException.InvalidPrologue -> RemoteHarnessCryptoFailure.INVALID_CONTEXT
        is NoiseException.InvalidState -> RemoteHarnessCryptoFailure.INVALID_STATE
        is NoiseException.MessageTooLarge, is NoiseException.InvalidMessage -> RemoteHarnessCryptoFailure.INVALID_MESSAGE
        is NoiseException.AuthenticationFailed, is NoiseException.PeerIdentityMismatch -> RemoteHarnessCryptoFailure.AUTHENTICATION
        is NoiseException.CounterExhausted -> RemoteHarnessCryptoFailure.COUNTER
        is NoiseException.Closed -> RemoteHarnessCryptoFailure.CLOSED
        is NoiseException.Unavailable -> RemoteHarnessCryptoFailure.UNAVAILABLE
    })
} catch (error: RemoteHarnessCryptoException) { throw error }
  catch (_: LinkageError) { throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.UNAVAILABLE) }
  catch (_: Exception) { throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.FAILED) }

private class NativeRemoteHarnessNoise(private var handle: NoiseIkSession?) : RemoteHarnessSecureNoise {
    private fun live() = handle ?: throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.CLOSED)
    override fun initiate(emptyPayload: ByteArray): ByteArray {
        if (emptyPayload.isNotEmpty()) throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.INVALID_MESSAGE)
        return sanitized { live().initiate() }
    }
    override fun readHandshake(bytes: ByteArray): RemoteHarnessSecureHandshakeResult = sanitized {
        val result = live().readHandshake(bytes)
        RemoteHarnessSecureHandshakeResult(result.complete, byteArrayOf(), result.response)
    }
    override fun counters(): RemoteHarnessSecureCounters = sanitized {
        val value = live().counters()
        if (value.sending > RemoteHarnessSecureLink.MAX_COUNTER.toULong() || value.receiving > RemoteHarnessSecureLink.MAX_COUNTER.toULong()) {
            try { shutdown() } catch (_: RemoteHarnessCryptoException) { }
            throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.COUNTER)
        }
        RemoteHarnessSecureCounters(value.complete, value.sending.toLong(), value.receiving.toLong())
    }
    override fun encrypt(plaintext: ByteArray): ByteArray = sanitized { live().encrypt(plaintext) }
    override fun decrypt(ciphertext: ByteArray): ByteArray = sanitized { live().decrypt(ciphertext) }
    override fun shutdown() {
        val current = handle ?: return; handle = null
        sanitized { try { current.shutdown() } finally { current.close() } }
    }
}
