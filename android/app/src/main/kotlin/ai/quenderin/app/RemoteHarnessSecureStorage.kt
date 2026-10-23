package ai.quenderin.app

import ai.quenderin.core.*
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Remote identity + atomic token pair have their own non-exportable wrapping key and private file.
 * A missing/inaccessible alias with an existing record is an error, never an identity reset. */
class AndroidRemoteHarnessCredentials(context: Context) : RemoteHarnessClientCredentialStore {
    private val atomic = AtomicFile(File(context.noBackupFilesDir, "remote-harness/credentials.bin"))
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(ALIAS)) return store.getKey(ALIAS, null) as? SecretKey ?: storageFailure()
        if (!create || atomic.baseFile.exists() || File(atomic.baseFile.path + ".bak").exists()) storageFailure()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    @Synchronized override fun read(): RemoteHarnessClientCredentials? = guarded {
        if (!atomic.baseFile.exists() && !File(atomic.baseFile.path + ".bak").exists()) {
            if (File(atomic.baseFile.path + ".new").exists()) storageFailure()
            return@guarded null
        }
        val bytes = atomic.openRead().use { boundedRead(it, 65_536 + 28) }
        requireFinalized(atomic)
        if (bytes.size !in 29..65_564) storageFailure()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(AAD)
        val plain = cipher.doFinal(bytes, 12, bytes.size - 12)
        try { RemoteHarnessClientRecords.credentials(strictUTF8(plain)) } finally { plain.fill(0); bytes.fill(0) }
    }
    @Synchronized override fun write(record: RemoteHarnessClientCredentials) = guarded {
        // Verify the previous committed record before touching a file or creating a key.
        read()
        val expected = RemoteHarnessClientRecords.credentials(record)
        val plaintext = expected.toByteArray(Charsets.UTF_8)
        try {
            if (plaintext.size > 65_536) storageFailure()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(true)); if (cipher.iv.size != 12) storageFailure()
            cipher.updateAAD(AAD)
            atomicWrite(atomic, cipher.iv + cipher.doFinal(plaintext))
            if (read()?.let(RemoteHarnessClientRecords::credentials) != expected) storageFailure()
        } finally { plaintext.fill(0) }
    }
    companion object {
        private const val ALIAS = "quenderin.remote-harness.aes.v1"
        private val AAD = "quenderin.remote-harness.credentials/v1/client".toByteArray(Charsets.UTF_8)
    }
}

/** Remote history/drafts are isolated from local and direct DeepSeek conversations. No import. */
class AndroidRemoteHarnessState(context: Context) : RemoteHarnessClientStateStore {
    private val atomic = AtomicFile(File(context.noBackupFilesDir, "remote-harness/session.json"))
    @Synchronized override fun read(): RemoteHarnessClientSavedState? = guarded {
        if (!atomic.baseFile.exists() && !File(atomic.baseFile.path + ".bak").exists()) {
            if (File(atomic.baseFile.path + ".new").exists()) storageFailure()
            return@guarded null
        }
        val source = atomic.openRead().use { strictUTF8(boundedRead(it, 4_194_304)) }
        requireFinalized(atomic)
        RemoteHarnessClientRecords.state(source)
    }
    @Synchronized override fun write(state: RemoteHarnessClientSavedState) = guarded {
        read()
        val source = RemoteHarnessClientRecords.state(state)
        atomicWrite(atomic, source.toByteArray(Charsets.UTF_8))
        if (read()?.let(RemoteHarnessClientRecords::state) != source) storageFailure()
    }
}

private fun storageFailure(): Nothing = throw RemoteHarnessException("client-storage")
private inline fun <T> guarded(block: () -> T): T = try { block() } catch (_: Exception) { storageFailure() }
private fun boundedRead(input: java.io.InputStream, maximum: Int): ByteArray {
    val out = ByteArrayOutputStream(); val buffer = ByteArray(4_096)
    while (true) { val count = input.read(buffer); if (count < 0) break
        if (out.size() > maximum - count) storageFailure(); out.write(buffer, 0, count) }
    return out.toByteArray()
}
private fun strictUTF8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
    .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
private fun requireFinalized(file: AtomicFile) {
    if (File(file.baseFile.path + ".new").exists() || File(file.baseFile.path + ".bak").exists()) storageFailure()
}
private fun atomicWrite(file: AtomicFile, bytes: ByteArray) {
    if (!file.baseFile.parentFile!!.isDirectory && !file.baseFile.parentFile!!.mkdirs()) storageFailure()
    val output = file.startWrite()
    try { output.write(bytes); output.fd.sync(); file.finishWrite(output) }
    catch (_: Exception) { file.failWrite(output); storageFailure() }
    requireFinalized(file)
}
