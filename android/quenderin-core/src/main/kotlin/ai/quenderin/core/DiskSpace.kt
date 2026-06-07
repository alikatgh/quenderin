package ai.quenderin.core

data class StorageCheckResult(
    val hasRoom: Boolean,
    val requiredBytes: Long,
    val availableBytes: Long,
    val message: String,
)

/**
 * Will a model's download actually fit? A 2 GB pull that fails at 95% full — the night
 * before someone goes off-grid — is exactly the failure to prevent. Pure check (the app
 * passes free bytes from `StatFs`). Mirrors iOS `DiskSpace`.
 */
object DiskSpace {

    /** Principled download-size estimate: params × bits-per-weight ÷ 8. */
    fun estimatedDownloadBytes(model: ModelEntry): Long {
        val bits = Quantization.info(model.quantization)?.bitsPerWeight ?: 4.5
        return (model.paramsBillions * 1_000_000_000.0 * bits / 8.0).toLong()
    }

    /** 300 MB margin covers OS overhead + KV cache spill. */
    fun check(model: ModelEntry, availableBytes: Long, marginBytes: Long = 300L * 1024 * 1024): StorageCheckResult {
        val required = estimatedDownloadBytes(model) + marginBytes
        val hasRoom = availableBytes >= required
        val message = if (hasRoom) {
            "${model.label}: needs ~${gb(required)} GB, ${gb(availableBytes)} GB free."
        } else {
            "Not enough space for ${model.label} — needs ~${gb(required)} GB but only ${gb(availableBytes)} GB free. " +
                "Free up space or pick a smaller model."
        }
        return StorageCheckResult(hasRoom, required, availableBytes, message)
    }

    private fun gb(bytes: Long): String = "%.1f".format(bytes / 1_000_000_000.0)
}
