package ai.quenderin.core

/**
 * Picks the right model for a device's RAM. 1:1 with the Swift `ModelRecommender`
 * and the desktop `getRecommendedModelIdForTotalRam` — Qwen3-first for mainstream
 * devices. Keep the thresholds identical across platforms.
 */
object ModelRecommender {

    fun recommendedModelId(totalRamGb: Double): String = when {
        totalRamGb < 1.5 -> "llama32-1b-q2"
        totalRamGb < 3.0 -> "llama32-1b"
        totalRamGb < 4.0 -> "llama32-3b"
        totalRamGb < 10.0 -> "qwen3-4b"   // the current go-to for mainstream devices
        else -> "qwen3-14b"
    }

    fun recommendedModel(totalRamGb: Double): ModelEntry =
        ModelCatalog.entry(recommendedModelId(totalRamGb)) ?: ModelCatalog.smallest
}
