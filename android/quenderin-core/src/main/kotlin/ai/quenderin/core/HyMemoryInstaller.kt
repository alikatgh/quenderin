package ai.quenderin.core

import java.io.File
import java.net.URI
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

data class HyMemoryInferenceRequest(val artifact: HyMemoryArtifactProof, val prompt: String) {
    val maxOutputTokens = 512
    val temperature = 0f
    val addBos = false
    val stopSequences = listOf("<eos:6124c78e>")
}
interface HyMemoryInferencePort {
    val unavailableReason: String?
    fun generate(request: HyMemoryInferenceRequest, onToken: (String) -> Unit): String
    fun cancel()
}

class HyMemoryArtifactProof internal constructor(val filePath: String, private val identity: Map<String, Any>) {
    val manifestSha256 = HyMemory.MANIFEST_SHA256
    val sha256 = HyMemory.SHA256
    val architecture = "hy_v3"
    val bytes = HyMemory.DOWNLOAD_BYTES
    fun assertCurrent() {
        require((identity["size"] as? Long) == bytes && identity == identity(File(filePath))) { "The verified Hy-Memory file changed. Verify it again." }
    }
    companion object {
        internal fun identity(file: File): Map<String, Any> {
            require(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) { "Hy-Memory must be a regular file, not a symlink." }
            return Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS)
        }
    }
}

/** Exact single pinned specialist only; no normal model catalog or answer-model selection. */
class HyMemoryInstaller(val directory: File, private val metadataMatches: (String) -> Boolean = ModelRuntimeSupport::hyMemoryMetadataMatches) {
    val file = File(directory, HyMemory.FILENAME)
    private val cancelled = AtomicBoolean(false)
    @Volatile private var connection: HttpsURLConnection? = null
    fun cancel() { cancelled.set(true); connection?.disconnect() }
    fun prepare() { cancelled.set(false) }
    fun isInstalled(): Boolean = Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) && file.length() == HyMemory.DOWNLOAD_BYTES
    private fun checkCancelled() { if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException("Hy-Memory operation cancelled.") }
    private fun resources(availableMemory: Long, freeDisk: Long, installing: Boolean) {
        require(availableMemory >= HyMemory.MINIMUM_MEMORY_BYTES) { "Hy-Memory requires at least 32 GiB of available app memory for the complete specialist." }
        require(freeDisk >= (if (installing) HyMemory.DOWNLOAD_BYTES else 0L) + 67_108_864L) { "Insufficient disk space for the complete Hy-Memory specialist and reserve." }
    }
    fun verify(availableMemory: Long, freeDisk: Long): HyMemoryArtifactProof { resources(availableMemory, freeDisk, false); return verifyFile(file) }
    private fun verifyFile(file: File): HyMemoryArtifactProof {
        checkCancelled(); val before = HyMemoryArtifactProof.identity(file)
        require((before["size"] as? Long) == HyMemory.DOWNLOAD_BYTES) { "Hy-Memory requires the complete pinned 18,236,702,240-byte GGUF." }
        require(ModelIntegrity.sha256Hex(file) { cancelled.get() } == HyMemory.SHA256 && before == HyMemoryArtifactProof.identity(file)) { "Hy-Memory checksum or file identity mismatch." }
        require(metadataMatches(file.path) && before == HyMemoryArtifactProof.identity(file)) { "The specialist must have actual hy_v3 architecture and unchanged pinned content." }
        return HyMemoryArtifactProof(file.path, before)
    }
    @Synchronized fun install(availableMemory: Long, freeDisk: Long, progress: (Float) -> Unit): HyMemoryArtifactProof {
        checkCancelled()
        if (file.exists()) return verify(availableMemory, freeDisk)
        resources(availableMemory, freeDisk, true)
        check(directory.mkdirs() || directory.isDirectory) { "Could not create the specialist folder." }
        require(directory.canonicalFile == directory.absoluteFile) { "The specialist folder must not contain symlinks." }
        val staging = File(directory, ".${UUID.randomUUID()}.partial")
        check(staging.createNewFile()) { "Could not create the specialist staging file." }
        try {
            var url = "https://huggingface.co/rapatsky/Hy-Memory-30B-A3B-GGUF/resolve/ac7974ba17f696b57c3c75229d127494b371f46f/${HyMemory.FILENAME}"
            var request: HttpsURLConnection? = null
            for (attempt in 0..8) {
                checkCancelled(); val uri = URI(url)
                require(uri.scheme == "https" && uri.userInfo == null) { "Refusing an unsafe specialist download URL." }
                val next = uri.toURL().openConnection() as HttpsURLConnection
                next.instanceFollowRedirects = false; next.connectTimeout = 30_000; next.readTimeout = 60_000
                connection = next
                if (next.responseCode in listOf(301, 302, 303, 307, 308)) {
                    val location = next.getHeaderField("Location") ?: error("Invalid download redirect.")
                    url = uri.resolve(location).toString(); next.disconnect(); continue
                }
                require(next.responseCode == 200) { "Unable to download the public pinned Hy-Memory artifact." }; request = next; break
            }
            val opened = request ?: error("Too many specialist download redirects.")
            try {
                require(opened.contentLengthLong < 0 || opened.contentLengthLong == HyMemory.DOWNLOAD_BYTES) { "Server returned the wrong specialist size." }
                var count = 0L; var reported = 0f
                opened.inputStream.use { input -> staging.outputStream().use { output ->
                    val buffer = ByteArray(65_536)
                    while (true) {
                        checkCancelled(); val read = input.read(buffer); if (read < 0) break
                        require(count + read <= HyMemory.DOWNLOAD_BYTES) { "Specialist download exceeded its pinned size." }
                        output.write(buffer, 0, read); count += read
                        val fraction = count.toFloat() / HyMemory.DOWNLOAD_BYTES
                        if (fraction - reported >= 0.002f) { reported = fraction; progress(fraction) }
                    }
                } }
                require(count == HyMemory.DOWNLOAD_BYTES) { "Specialist download was incomplete." }
            } finally { opened.disconnect(); connection = null }
            verifyFile(staging).assertCurrent(); checkCancelled()
            Files.move(staging.toPath(), file.toPath()) // No replacement of an existing file.
            progress(1f); return verifyFile(file)
        } finally { if (staging.exists()) staging.delete() }
    }
}
