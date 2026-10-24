package ai.quenderin.core

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

/** Process-local SHA receipts. Exact filesystem identity is rechecked at every handoff and after load.
 * Paths/stamps remain in memory; none enters numeric performance history. */
class ModelArtifactVerificationReceipts(
    private val verifyBytes: (ModelEntry, String) -> Boolean = { model, path -> ModelArtifacts.isComplete(model, path) },
    private val nanoTime: () -> Long = System::nanoTime,
) {
    data class Receipt internal constructor(val artifactSHA256: String, val path: String,
        internal val stamps: List<String>, val verificationMs: Double, internal val createdAtNanos: Long)
    private val receipts = LinkedHashMap<String, Receipt>()
    private fun key(model: ModelEntry, path: String): String? = InferencePerformanceIdentity.artifact(model)
        ?.let { "$it|${File(path).absolutePath}" }

    @Synchronized fun current(model: ModelEntry, path: String): Receipt? {
        val key = key(model, path) ?: return null
        val proof = receipts[key] ?: return null
        if (stamps(model, path) != proof.stamps) {
            receipts.remove(key); return null
        }
        return proof
    }

    /** A currently loaded engine can retain its original byte-verified proof across LRU eviction.
     * Exact identity/stamps still have to match; elapsed wall time alone cannot invalidate unchanged bytes. */
    @Synchronized fun retainLoaded(model: ModelEntry, proof: Receipt): Boolean {
        val key = key(model, proof.path) ?: return false
        if (InferencePerformanceIdentity.artifact(model) != proof.artifactSHA256 || stamps(model, proof.path) != proof.stamps) return false
        receipts.remove(key); receipts[key] = proof
        while (receipts.size > 64) receipts.remove(receipts.keys.first())
        return true
    }

    @Synchronized fun verify(model: ModelEntry, path: String): Receipt? {
        current(model, path)?.let { return it }
        val key = key(model, path) ?: return null
        val before = stamps(model, path) ?: return null
        val start = nanoTime()
        if (!verifyBytes(model, path)) return null
        val elapsedMs = (nanoTime() - start).coerceAtLeast(0) / 1_000_000.0
        if (before != stamps(model, path)) return null
        val receipt = Receipt(InferencePerformanceIdentity.artifact(model)!!, File(path).absolutePath,
            before, elapsedMs, nanoTime())
        receipts.remove(key); receipts[key] = receipt
        while (receipts.size > 64) receipts.remove(receipts.keys.first())
        return receipt
    }

    private fun stamps(model: ModelEntry, path: String): List<String>? = try {
        ModelArtifacts.entries(model).map { part ->
            val file = if (model.artifacts.isEmpty()) File(path) else File(File(path).parentFile, part.filename)
            check(Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS))
            val attrs = Files.readAttributes(file.toPath(), "unix:dev,ino,size,lastModifiedTime,ctime", LinkOption.NOFOLLOW_LINKS)
            listOf("dev", "ino", "size", "lastModifiedTime", "ctime").joinToString("|") { attrs.getValue(it).toString() }
        }
    } catch (_: Exception) { null }

    companion object { val process = ModelArtifactVerificationReceipts() }
}
