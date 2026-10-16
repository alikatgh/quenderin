package ai.quenderin.core

import java.io.File
import java.net.URI
import java.util.Locale

/** Validates catalog metadata before any path, disk, or network operation. */
object ModelArtifacts {
    const val MAX_PARTS = 64
    private val basename = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,234}\\.gguf$", RegexOption.IGNORE_CASE)
    private val sha256 = Regex("^[a-fA-F0-9]{64}$")
    private val splitName = Regex("^(.+)-(\\d{5})-of-(\\d{5})\\.gguf$", RegexOption.IGNORE_CASE)
    private val pinnedPath = Regex("^/[A-Za-z0-9_-][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*/resolve/[a-fA-F0-9]{40}/[A-Za-z0-9._/-]+\\.gguf$", RegexOption.IGNORE_CASE)

    fun validate(model: ModelEntry) {
        require(basename.matches(model.filename) && !model.filename.contains("..")) { "Invalid model filename" }
        if (model.artifacts.isEmpty()) return
        require(model.artifacts.size in 1..MAX_PARTS) { "Invalid model shard count" }
        val names = HashSet<String>()
        val urls = HashSet<String>()
        var total = 0L
        for (part in model.artifacts) {
            require(basename.matches(part.filename) && !part.filename.contains("..")) { "Invalid shard filename" }
            require(names.add(part.filename.lowercase(Locale.ROOT))) { "Duplicate shard filename" }
            require(sha256.matches(part.sha256) && part.downloadBytes > 0L) { "Invalid shard integrity metadata" }
            val uri = runCatching { URI(part.url) }.getOrNull()
            require(uri != null && uri.scheme == "https" && uri.host == "huggingface.co" &&
                uri.userInfo == null && uri.port == -1 && uri.fragment == null &&
                (uri.rawQuery == null || uri.rawQuery == "download=true") &&
                pinnedPath.matches(uri.rawPath) && uri.rawPath.split('/').none { it == "." || it == ".." } &&
                uri.rawPath.substringAfterLast('/') == part.filename) { "Shard URL must pin an immutable Hugging Face revision" }
            require(urls.add(uri.rawPath)) { "Duplicate shard URL" }
            require(total <= Long.MAX_VALUE - part.downloadBytes) { "Model shard size overflow" }
            total += part.downloadBytes
        }
        val split = splitName.matchEntire(model.artifacts.first().filename)
        if (split != null) {
            val prefix = split.groupValues[1]
            val count = split.groupValues[3].toInt()
            require(count == model.artifacts.size) { "Model manifest is missing GGUF shards" }
            model.artifacts.forEachIndexed { index, part ->
                val name = splitName.matchEntire(part.filename)
                require(name != null && name.groupValues[1] == prefix &&
                    name.groupValues[2].toInt() == index + 1 && name.groupValues[3].toInt() == count) {
                    "GGUF shard sequence does not match the complete model manifest"
                }
            }
        } else {
            require(model.artifacts.none { splitName.matches(it.filename) }) { "Inconsistent GGUF shard naming" }
        }
        val first = model.artifacts.first()
        require(model.filename == first.filename && model.url == first.url && model.sha256 == first.sha256) {
            "Model file metadata must identify the first shard"
        }
        require(model.downloadBytes == total) { "Model download size must include every shard" }
    }

    fun filenames(model: ModelEntry): List<String> {
        validate(model)
        return if (model.artifacts.isEmpty()) listOf(model.filename) else model.artifacts.map { it.filename }
    }

    internal fun entries(model: ModelEntry): List<ModelEntry> {
        validate(model)
        return if (model.artifacts.isEmpty()) listOf(model) else model.artifacts.map { part ->
            model.copy(filename = part.filename, url = part.url, sha256 = part.sha256,
                downloadBytes = part.downloadBytes, artifacts = emptyList())
        }
    }

    /** Always verifies the full split set; a tiny metadata shard can never establish readiness. */
    fun isComplete(model: ModelEntry, firstPath: String, sink: FileSink = JvmFileSink(),
                   isCancelled: () -> Boolean = { false }): Boolean {
        validate(model)
        val first = File(firstPath)
        if (model.artifacts.isNotEmpty() && first.name != model.filename) return false
        return entries(model).all { part ->
            if (isCancelled()) throw DownloadCancelledException("Model verification cancelled.")
            val path = if (model.artifacts.isEmpty()) firstPath else File(first.parentFile, part.filename).path
            val size = sink.existingSize(path)
            size > 0L && (model.artifacts.isEmpty() || size == part.downloadBytes) &&
                ModelIntegrity.hasGGUFMagic(sink.head(path, 4)) &&
                (part.sha256 == null || sink.sha256(path, isCancelled).equals(part.sha256, ignoreCase = true))
        }
    }

    fun requireComplete(model: ModelEntry, firstPath: String, isCancelled: () -> Boolean = { false }) {
        check(isComplete(model, firstPath, isCancelled = isCancelled)) { "Model is incomplete or corrupt: every GGUF shard must pass integrity verification." }
    }

    /** Candidate for an offline verification job. This does not grant load/readiness permission. */
    fun hasCompleteFileSet(model: ModelEntry, destinationDir: String, sink: FileSink = JvmFileSink()): Boolean {
        validate(model)
        return model.artifacts.isNotEmpty() && model.artifacts.all {
            sink.existingSize(File(destinationDir, it.filename).path) == it.downloadBytes
        }
    }

    /** Credits retained bytes when preflighting the entire split model for a resume. */
    fun remainingDownloadBytes(model: ModelEntry, destinationDir: String, sink: FileSink = JvmFileSink(),
                               isCancelled: () -> Boolean = { false }): Long =
        remainingBytes(model, destinationDir, sink, verifyExisting = true, isCancelled)

    /** Cheap UI estimate only. Download/load still verify every byte on their background path. */
    fun estimatedRemainingDownloadBytes(model: ModelEntry, destinationDir: String, sink: FileSink = JvmFileSink()): Long =
        remainingBytes(model, destinationDir, sink, verifyExisting = false, isCancelled = { false })

    private fun remainingBytes(model: ModelEntry, destinationDir: String, sink: FileSink, verifyExisting: Boolean,
                               isCancelled: () -> Boolean): Long {
        validate(model)
        if (model.artifacts.isEmpty()) return DiskSpace.estimatedDownloadBytes(model)
        return model.artifacts.sumOf { part ->
            if (isCancelled()) throw DownloadCancelledException("Model verification cancelled.")
            val path = File(destinationDir, part.filename).path
            val complete = sink.existingSize(path) == part.downloadBytes &&
                (!verifyExisting || (ModelIntegrity.hasGGUFMagic(sink.head(path, 4)) &&
                    sink.sha256(path, isCancelled).equals(part.sha256, ignoreCase = true)))
            if (complete) 0L else part.downloadBytes - sink.existingSize("$path.part").coerceIn(0L, part.downloadBytes)
        }
    }
}
