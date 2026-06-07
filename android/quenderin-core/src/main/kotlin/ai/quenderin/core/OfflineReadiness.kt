package ai.quenderin.core

/**
 * The trust signal the off-grid user is missing: *is this model actually, completely
 * downloaded — safe to walk away from Wi-Fi?* Mirrors iOS `OfflineReadiness`.
 */
data class OfflineReadiness(val model: ModelEntry, val status: Status) {
    sealed interface Status {
        object NotDownloaded : Status
        data class Incomplete(val downloadedBytes: Long, val expectedBytes: Long) : Status
        object Ready : Status
    }

    val isReadyForOffline: Boolean get() = status is Status.Ready

    val message: String
        get() = when (val s = status) {
            is Status.Ready -> "✅ ${model.label} is downloaded and ready. You can go offline."
            is Status.NotDownloaded -> "${model.label} isn't downloaded yet. Download it while you have Wi-Fi."
            is Status.Incomplete -> {
                val pct = if (s.expectedBytes > 0) (s.downloadedBytes.toDouble() / s.expectedBytes * 100).toInt() else 0
                "${model.label} is only $pct% downloaded — finish before you lose Wi-Fi."
            }
        }
}

object OfflineReadinessChecker {
    /**
     * Pure check from a known file size — deterministic for tests. A model is "ready"
     * when its file is ≥ 85% of the estimate (a complete GGUF comfortably exceeds it; a
     * truncated partial won't). The app supplies the real size via `File.length()`.
     */
    fun evaluate(model: ModelEntry, fileExists: Boolean, fileSizeBytes: Long): OfflineReadiness {
        if (!fileExists || fileSizeBytes <= 0L) {
            return OfflineReadiness(model, OfflineReadiness.Status.NotDownloaded)
        }
        val expected = DiskSpace.estimatedDownloadBytes(model)
        return if (fileSizeBytes >= expected * 0.85) {
            OfflineReadiness(model, OfflineReadiness.Status.Ready)
        } else {
            OfflineReadiness(model, OfflineReadiness.Status.Incomplete(fileSizeBytes, expected))
        }
    }
}
