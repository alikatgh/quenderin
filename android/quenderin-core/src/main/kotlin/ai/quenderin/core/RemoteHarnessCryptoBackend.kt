package ai.quenderin.core

enum class RemoteHarnessCryptoFailure { UNAVAILABLE, INVALID_KEY, INVALID_CONTEXT, INVALID_STATE, INVALID_MESSAGE, AUTHENTICATION, COUNTER, CLOSED, FAILED }
class RemoteHarnessCryptoException(val failure: RemoteHarnessCryptoFailure) : Exception("Remote Harness cryptography: ${failure.name}")

interface RemoteHarnessCryptoBackend {
    val isAvailable: Boolean
    fun publicKey(privateSeed: ByteArray): ByteArray
    fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo): RemoteHarnessSecureNoise
}

object RemoteHarnessCryptoBackends {
    /** One fixed provider, packaged only with verified native artifacts. Pure JVM fixtures need no JNA. */
    fun native(): RemoteHarnessCryptoBackend = try {
        Class.forName("ai.quenderin.remote.crypto.NativeRemoteHarnessCryptoBackend")
            .getDeclaredConstructor().newInstance() as RemoteHarnessCryptoBackend
    } catch (_: ReflectiveOperationException) { UnavailableRemoteHarnessCryptoBackend }
      catch (_: LinkageError) { UnavailableRemoteHarnessCryptoBackend }
}

private object UnavailableRemoteHarnessCryptoBackend : RemoteHarnessCryptoBackend {
    override val isAvailable = false
    override fun publicKey(privateSeed: ByteArray): ByteArray = throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.UNAVAILABLE)
    override fun initiator(privateSeed: ByteArray, peerPublicKey: ByteArray, info: RemoteHarnessSecureConnectionInfo): RemoteHarnessSecureNoise =
        throw RemoteHarnessCryptoException(RemoteHarnessCryptoFailure.UNAVAILABLE)
}
