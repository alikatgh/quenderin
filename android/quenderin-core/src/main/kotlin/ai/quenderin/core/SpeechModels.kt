package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.concurrent.CancellationException

data class SpeechVadModel(
    val id: String,
    val label: String,
    val repo: String,
    val revision: String,
    val filename: String,
    val localFilename: String,
    val bytes: Long,
    val sha256: String,
    val architecture: String,
    val variant: String,
    val license: String,
    val access: String,
) {
    val downloadUrl: String
        get() = "https://huggingface.co/$repo/resolve/$revision/$filename?download=true"

    fun validate() {
        val safeName = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$")
        require(safeName.matches(id) && !id.contains("..") &&
            safeName.matches(localFilename) && !localFilename.contains("..") &&
            localFilename.endsWith(".gguf") &&
            Regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$").matches(repo) &&
            Regex("^[a-f0-9]{40}$").matches(revision) &&
            Regex("^[a-f0-9]{64}$").matches(sha256) &&
            bytes in 1 until 10_000_000_000L) {
            "Invalid speech VAD manifest"
        }
    }
}

data class SpeechModel(
    val id: String,
    val label: String,
    val engine: String,
    val architecture: String,
    val variant: String,
    val repo: String? = null,
    val revision: String? = null,
    val filename: String? = null,
    val localFilename: String? = null,
    val bytes: Long? = null,
    val sha256: String? = null,
    val languages: List<String>,
    val acceptsLanguageHint: Boolean = false,
    val supportsLanguageDetection: Boolean = false,
    val streams: Boolean = false,
    val vocabularyUse: String = "none",
    val realtime: String? = null,
    val wordErrorRate: Double? = null,
    val license: String,
    val access: String,
) {
    val isOnDeviceFramework: Boolean get() = engine == "apple_speech"

    val downloadUrl: String?
        get() = if (!isOnDeviceFramework && repo != null && revision != null && filename != null) {
            "https://huggingface.co/$repo/resolve/$revision/$filename?download=true"
        } else {
            null
        }

    fun validate() {
        val safeName = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,239}$")
        require(safeName.matches(id) && !id.contains("..") && languages.isNotEmpty()) {
            "Invalid speech model identity"
        }
        when (engine) {
            "transcribe.cpp" -> {
                val file = requireNotNull(localFilename) { "Missing local filename for $id" }
                val rev = requireNotNull(revision) { "Missing revision for $id" }
                val sum = requireNotNull(sha256) { "Missing SHA-256 for $id" }
                val size = requireNotNull(bytes) { "Missing byte count for $id" }
                val repository = requireNotNull(repo) { "Missing repo for $id" }
                require(safeName.matches(file) && !file.contains("..") &&
                    (file.endsWith(".gguf") || file.endsWith(".bin")) &&
                    Regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$").matches(repository) &&
                    Regex("^[a-f0-9]{40}$").matches(rev) &&
                    Regex("^[a-f0-9]{64}$").matches(sum) &&
                    size in 1 until 50_000_000_000L) {
                    "Invalid speech model artifact metadata for $id"
                }
            }
            "apple_speech" -> Unit
            else -> error("Unsupported speech engine $engine")
        }
    }
}

object SpeechModelFiles {
    fun verify(
        model: SpeechModel,
        directory: File,
        vad: SpeechVadModel? = null,
        cancelled: () -> Boolean = { false },
    ) {
        model.validate()
        require(!model.isOnDeviceFramework) { "On-device Apple Speech model cannot run on Android GGUF runtime" }
        require(directory.canonicalFile == directory.absoluteFile) {
            "Speech model directory must not contain symbolic links"
        }
        verifyFile(
            file = File(directory, requireNotNull(model.localFilename)),
            expectedBytes = requireNotNull(model.bytes),
            expectedSha256 = requireNotNull(model.sha256),
            cancelled = cancelled,
        )
        if (vad != null) {
            vad.validate()
            verifyFile(
                file = File(directory, vad.localFilename),
                expectedBytes = vad.bytes,
                expectedSha256 = vad.sha256,
                cancelled = cancelled,
            )
        }
    }

    fun verifyFile(
        file: File,
        expectedBytes: Long,
        expectedSha256: String,
        cancelled: () -> Boolean = { false },
    ) {
        val path = file.toPath()
        require(Files.exists(path, LinkOption.NOFOLLOW_LINKS) &&
            !Files.isSymbolicLink(path) &&
            file.canonicalFile == file.absoluteFile &&
            file.isFile &&
            file.length() == expectedBytes) {
            "Missing or incomplete ${file.name}"
        }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                if (cancelled()) throw CancellationException("Speech verification cancelled")
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        require(actual == expectedSha256 && file.length() == expectedBytes) {
            "Checksum failed for ${file.name}"
        }
    }
}
