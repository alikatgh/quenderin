package ai.quenderin.core

/**
 * A record of an in-flight model download — so progress survives the app being suspended
 * or killed, and can be resumed on relaunch. Mirrors iOS `PersistedDownload`.
 */
data class PersistedDownload(
    val modelId: String,
    val fileName: String,
    val urlString: String,
    val destinationPath: String,
    val bytesDownloaded: Long = 0,
    val totalBytes: Long = 0,
    val state: State = State.RUNNING,
) {
    enum class State { RUNNING, PAUSED, COMPLETED, FAILED }

    val fractionComplete: Double
        get() = if (totalBytes > 0) minOf(1.0, bytesDownloaded.toDouble() / totalBytes) else 0.0

    /** Byte offset to resume from (an HTTP `Range:` value) — 0 once complete. */
    val resumeOffset: Long
        get() = if (state != State.COMPLETED) bytesDownloaded else 0L
}

/**
 * In-memory table of in-flight downloads keyed by modelId — the bookkeeping that makes a
 * download resumable across relaunch. The app persists [snapshot] (e.g. to a file or
 * SharedPreferences) and restores via the constructor; here it's pure so it unit-tests on
 * the JVM. Mirrors iOS `DownloadStore` (a file-backed actor). The real bytes-on-disk work
 * is a `WorkManager` job — the app/cliff layer.
 */
class DownloadStore(initial: List<PersistedDownload> = emptyList()) {
    private val records = LinkedHashMap<String, PersistedDownload>()

    /** Notified after any change, so the app can persist the [snapshot]. */
    var onChange: (List<PersistedDownload>) -> Unit = {}

    init {
        initial.forEach { records[it.modelId] = it }
    }

    fun upsert(record: PersistedDownload) {
        records[record.modelId] = record
        emit()
    }

    fun get(modelId: String): PersistedDownload? = records[modelId]

    fun all(): List<PersistedDownload> = records.values.toList()

    fun remove(modelId: String) {
        if (records.remove(modelId) != null) emit()
    }

    fun updateProgress(modelId: String, bytesDownloaded: Long, totalBytes: Long) {
        val r = records[modelId] ?: return
        records[modelId] = r.copy(
            bytesDownloaded = bytesDownloaded,
            totalBytes = if (totalBytes > 0) totalBytes else r.totalBytes,
        )
        emit()
    }

    fun setState(modelId: String, state: PersistedDownload.State) {
        val r = records[modelId] ?: return
        records[modelId] = r.copy(state = state)
        emit()
    }

    /** The full table, for the app to persist across launches. */
    fun snapshot(): List<PersistedDownload> = all()

    /** Downloads mid-flight when the app last died — the resume set. Twin of iOS `resumable()`. */
    fun resumable(): List<PersistedDownload> =
        records.values.filter {
            it.state == PersistedDownload.State.RUNNING || it.state == PersistedDownload.State.PAUSED
        }

    private fun emit() = onChange(all())
}
