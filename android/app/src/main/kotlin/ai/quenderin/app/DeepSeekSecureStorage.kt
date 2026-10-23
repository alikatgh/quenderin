package ai.quenderin.app

import ai.quenderin.core.ConnectionKind
import ai.quenderin.core.ConnectionProfile
import ai.quenderin.core.DeepSeekConversation
import ai.quenderin.core.DeepSeekCredentialVault
import ai.quenderin.core.DeepSeekException
import ai.quenderin.core.DeepSeekFailure
import ai.quenderin.core.DeepSeekPersistence
import ai.quenderin.core.NativeConnectionsCodec
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Android Keystore keeps the wrapping key non-exportable. Preferences contain IV+ciphertext only.
 * Keystore invalidation, corrupt ciphertext, missing keys and failed commits all fail closed. */
class AndroidDeepSeekVault(context: Context) : DeepSeekCredentialVault {
    private val preferences = context.getSharedPreferences("deepseek_credentials", Context.MODE_PRIVATE)
    private val keyStore get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun wrappingKey(create: Boolean): SecretKey {
        val store = keyStore
        if (store.containsAlias(ALIAS)) return (store.getKey(ALIAS, null) as? SecretKey)
            ?: throw DeepSeekException(DeepSeekFailure.STORAGE)
        if (!create) throw DeepSeekException(DeepSeekFailure.STORAGE)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    @Synchronized override fun save(key: CharArray): String = guarded {
        if (key.isEmpty() || key.size > 256 || key.any { it.code !in 33..126 }) throw DeepSeekException(DeepSeekFailure.CREDENTIAL)
        // A failed preference commit can leave an encrypted staged row in the process cache.
        // Bound those uncertain rows; explicit Remove saved API keys clears them and the alias.
        if (preferences.all.size >= MAX_CREDENTIALS) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val buffer = Charsets.UTF_8.encode(CharBuffer.wrap(key))
        val plaintext = ByteArray(buffer.remaining()).also { buffer.get(it) }
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey(create = true))
            if (cipher.iv.size != 12) throw DeepSeekException(DeepSeekFailure.STORAGE)
            val reference = "qcred:${UUID.randomUUID()}"
            cipher.updateAAD(reference.toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(plaintext)
            val bytes = cipher.iv + encrypted
            if (!preferences.edit().putString(reference, Base64.encodeToString(bytes, Base64.NO_WRAP)).commit())
                throw DeepSeekException(DeepSeekFailure.STORAGE)
            reference
        } finally { plaintext.fill(0); if (buffer.hasArray()) buffer.array().fill(0) }
    }
    override fun <T> use(reference: String, action: (CharArray) -> T): T {
        val chars = decrypt(reference)
        return try { action(chars) } finally { chars.fill('\u0000') }
    }
    @Synchronized private fun decrypt(reference: String): CharArray = guarded {
        if (!REFERENCE.matches(reference)) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val encoded = preferences.getString(reference, null) ?: throw DeepSeekException(DeepSeekFailure.CREDENTIAL)
        if (encoded.length > 512) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        if (bytes.size !in 29..284) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(create = false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(reference.toByteArray(Charsets.UTF_8))
        val plaintext = cipher.doFinal(bytes, 12, bytes.size - 12)
        try {
            val buffer = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(plaintext))
            CharArray(buffer.remaining()).also { buffer.get(it); if (buffer.hasArray()) buffer.array().fill('\u0000') }
        } finally { plaintext.fill(0) }
    }
    @Synchronized override fun remove(reference: String) = guarded {
        if (!REFERENCE.matches(reference) || !preferences.edit().remove(reference).commit())
            throw DeepSeekException(DeepSeekFailure.STORAGE)
    }
    @Synchronized override fun removeAll() = guarded {
        val cleared = runCatching { preferences.edit().clear().commit() }.getOrDefault(false)
        // Key invalidation makes any ciphertext left by an uncertain preference commit unusable.
        keyStore.deleteEntry(ALIAS)
        if (!cleared) throw DeepSeekException(DeepSeekFailure.STORAGE)
    }
    private inline fun <T> guarded(action: () -> T): T = try { action() }
        catch (e: DeepSeekException) { throw e }
        catch (_: Exception) { throw DeepSeekException(DeepSeekFailure.STORAGE) }
    companion object {
        private const val ALIAS = "quenderin.deepseek.aes.v1"
        private const val MAX_CREDENTIALS = 64
        private val REFERENCE = Regex("^qcred:[a-f0-9-]{36}$")
    }
}

/** Cloud transcripts have their own versioned store; local chat persistence is never read here. */
class AndroidDeepSeekPersistence(context: Context) : DeepSeekPersistence {
    private val profileFile = AtomicFile(File(context.noBackupFilesDir, "deepseek-profile.json"))
    private val directory = File(context.noBackupFilesDir, "deepseek-conversations")
    override fun readProfile(): ConnectionProfile? = safe {
        if (!profileFile.baseFile.exists() && !File(profileFile.baseFile.path + ".bak").exists()) {
            // A first profile write interrupted before commit can leave only .new. There is no
            // committed account to restore: stay disconnected and preserve that staged file and
            // encrypted keys until an explicit Connect or Remove saved API keys action.
            return@safe null
        }
        val source = profileFile.openRead().use { input ->
            val bytes = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(4_096)
            while (true) {
                val count = input.read(buffer); if (count < 0) break
                if (bytes.size() + count > 16_384) throw DeepSeekException(DeepSeekFailure.STORAGE)
                bytes.write(buffer, 0, count)
            }
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        }
        requireFinalized(profileFile)
        if (source == "null") return@safe null
        NativeConnectionsCodec.decodeProfile(source).also {
            if (it.kind != ConnectionKind.DEEPSEEK || it.credentialReference == null) throw DeepSeekException(DeepSeekFailure.STORAGE)
        }
    }
    override fun writeProfile(profile: ConnectionProfile?) = safe {
        val expected = profile?.let(NativeConnectionsCodec::encodeProfile) ?: "null"
        val bytes = expected.toByteArray(Charsets.UTF_8)
        if (bytes.size > 16_384) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val output = profileFile.startWrite()
        try { output.write(bytes); output.fd.sync(); profileFile.finishWrite(output) }
        catch (_: Exception) { profileFile.failWrite(output); throw DeepSeekException(DeepSeekFailure.STORAGE) }
        requireFinalized(profileFile)
        // Some Android AtomicFile implementations log a failed rename instead of throwing.
        // Confirm the installed record before a caller is allowed to retire the prior key.
        if ((readProfile()?.let(NativeConnectionsCodec::encodeProfile) ?: "null") != expected)
            throw DeepSeekException(DeepSeekFailure.STORAGE)
    }
    override fun readConversations(): List<DeepSeekConversation> = safe {
        // API28's AtomicFile can leave only a legacy .bak after process death. Recover that known
        // journal through AtomicFile instead of silently omitting it from the history list.
        val files = directory.listFiles { file -> file.name.matches(Regex("^[a-zA-Z0-9-]+\\.json(\\.bak)?$")) }
            ?.map { File(directory, it.name.removeSuffix(".bak")) }?.distinctBy { it.name } ?: emptyList()
        if (files.size > MAX_CONVERSATIONS) throw DeepSeekException(DeepSeekFailure.STORAGE)
        files.sortedByDescending { it.lastModified() }.map { file ->
            if (file.length() > 8_388_608) throw DeepSeekException(DeepSeekFailure.STORAGE)
            val atomic = AtomicFile(file)
            atomic.openRead().use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (true) {
                    val count = input.read(buffer); if (count < 0) break
                    if (output.size().toLong() + count > 8_388_608) throw DeepSeekException(DeepSeekFailure.STORAGE)
                    output.write(buffer, 0, count)
                }
                val bytes = output.toByteArray()
                val decoded = DeepSeekConversation.decode(Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString())
                requireFinalized(atomic)
                decoded
            }
        }
    }
    override fun writeConversation(conversation: DeepSeekConversation) = safe {
        val id = conversation.envelope.conversationID
        if (!id.matches(Regex("^[a-zA-Z0-9-]{1,128}$"))) throw DeepSeekException(DeepSeekFailure.STORAGE)
        if (!directory.isDirectory && !directory.mkdirs()) throw DeepSeekException(DeepSeekFailure.STORAGE)
        val file = File(directory, "$id.json")
        if (!file.exists() && (directory.listFiles()?.count { it.extension == "json" } ?: 0) >= MAX_CONVERSATIONS)
            throw DeepSeekException(DeepSeekFailure.STORAGE)
        val expected = conversation.encode()
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try { output.write(expected.toByteArray(Charsets.UTF_8)); output.fd.sync(); atomic.finishWrite(output) }
        catch (_: Exception) { atomic.failWrite(output); throw DeepSeekException(DeepSeekFailure.STORAGE) }
        requireFinalized(atomic)
        // A paid request is admitted only after the exact pending turn is installed and readable.
        val actual = atomic.openRead().use { input ->
            val bytes = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = input.read(buffer); if (count < 0) break
                if (bytes.size().toLong() + count > 8_388_608) throw DeepSeekException(DeepSeekFailure.STORAGE)
                bytes.write(buffer, 0, count)
            }
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        }
        if (actual != expected) throw DeepSeekException(DeepSeekFailure.STORAGE)
        requireFinalized(atomic)
    }
    private fun requireFinalized(file: AtomicFile) {
        if (File(file.baseFile.path + ".new").exists() || File(file.baseFile.path + ".bak").exists())
            throw DeepSeekException(DeepSeekFailure.STORAGE)
    }
    private inline fun <T> safe(action: () -> T): T = try { action() }
        catch (e: DeepSeekException) { throw e }
        catch (_: Exception) { throw DeepSeekException(DeepSeekFailure.STORAGE) }
    companion object { const val MAX_CONVERSATIONS = 30 }
}
