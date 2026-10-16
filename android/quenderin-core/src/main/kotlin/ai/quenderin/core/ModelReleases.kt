package ai.quenderin.core

import java.time.Instant

/** Discovery metadata never becomes a ModelEntry without matching a shipped file checksum. */
data class ModelRelease(
    val id: String,
    val name: String,
    val createdAt: String,
    val quantization: String,
    val downloadBytes: Long,
    val sha256: String,
    val revision: String,
    val filename: String,
    val license: String,
) {
    val sourceUrl: String get() = "https://huggingface.co/$id"
    val downloadGB: Double get() = downloadBytes / 1_000_000_000.0
    fun catalogEntry(models: List<ModelEntry> = ModelCatalog.models): ModelEntry? =
        models.firstOrNull { it.sha256?.equals(sha256, ignoreCase = true) == true }

    fun isValid(): Boolean =
        Regex("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,95}/[A-Za-z0-9_-][A-Za-z0-9._-]{0,95}$").matches(id) &&
            name.isNotEmpty() && name.length <= 160 && name.none { it == '\n' || it == '\r' || it == '\u0000' } &&
            ModelReleaseFeed.instant(createdAt) != null &&
            Regex("^[A-Za-z0-9_-]{1,32}$").matches(quantization) &&
            downloadBytes in 200_000_000L..24_000_000_000L &&
            Regex("^[a-fA-F0-9]{64}$").matches(sha256) && Regex("^[a-fA-F0-9]{40}$").matches(revision) &&
            filename.toByteArray(Charsets.UTF_8).size <= 240 && filename.endsWith(".gguf", ignoreCase = true) &&
            !filename.contains('/') && !filename.contains('\\') && !filename.contains("..") &&
            filename.none { it == '\n' || it == '\r' || it == '\u0000' } && license.length <= 120
}

data class ModelReleaseFeed(
    val version: Int,
    val checkedAt: String,
    val partial: Boolean,
    val models: List<ModelRelease>,
    val freshness: String? = null,
) {
    fun validated(): ModelReleaseFeed {
        require(version == 1 && instant(checkedAt) != null && models.size in 1..60) { "Invalid release feed" }
        val valid = models.filter { it.isValid() }.distinctBy { it.id }.sortedByDescending { instant(it.createdAt) }
        require(valid.isNotEmpty()) { "No valid releases" }
        return copy(models = valid, partial = partial || valid.size != models.size)
    }

    companion object {
        const val MAX_BYTES = 1_048_576
        const val REFRESH_MILLIS = 3_600_000L
        fun instant(value: String): Instant? = runCatching { Instant.parse(value) }.getOrNull()
    }
}

data class ModelReleaseSnapshot(val feed: ModelReleaseFeed, val saved: Boolean, val refreshFailed: Boolean)

interface ModelReleaseCache {
    fun load(): ModelReleaseFeed?
    fun save(feed: ModelReleaseFeed)
}

/** Small, injectable offline store. Call refresh on an IO worker; concurrent callers coalesce. */
class ModelReleaseRepository(
    private val cache: ModelReleaseCache,
    bundled: ModelReleaseFeed,
    private val fetch: () -> ModelReleaseFeed,
) {
    @Volatile var snapshot: ModelReleaseSnapshot
        private set
    private var lastAttempt: Long? = null

    init {
        val seed = bundled.validated()
        val saved = runCatching { cache.load()?.validated() }.getOrNull()
        val feed = if (saved != null && ModelReleaseFeed.instant(saved.checkedAt)!! >= ModelReleaseFeed.instant(seed.checkedAt)!!) saved else seed
        snapshot = ModelReleaseSnapshot(feed, saved = true, refreshFailed = false)
    }

    @Synchronized fun refresh(force: Boolean = false, now: Long = System.currentTimeMillis()): ModelReleaseSnapshot {
        val delay = if (snapshot.refreshFailed) 60_000L else ModelReleaseFeed.REFRESH_MILLIS
        if (!force && lastAttempt?.let { now - it in 0 until delay } == true) return snapshot
        lastAttempt = now
        try {
            val feed = fetch().validated()
            require(ModelReleaseFeed.instant(feed.checkedAt)!! >= ModelReleaseFeed.instant(snapshot.feed.checkedAt)!!) { "Older release feed" }
            snapshot = ModelReleaseSnapshot(feed, saved = feed.freshness == "saved", refreshFailed = false)
            // A full/read-only disk must not throw away the visible results or existing cache.
            runCatching { cache.save(feed) }
        } catch (_: Exception) {
            snapshot = snapshot.copy(saved = true, refreshFailed = true)
        }
        return snapshot
    }
}
