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

    /**
     * The recommendation a UI can actually OFFER: the RAM-band pick when it passes the memory
     * gate, else the largest catalog model that does (falling back to the smallest). Twin of the
     * Swift `bestInstallableModel` — the band and [MemoryFitness] can disagree (a 16 GB device
     * band-picks the 14B, which the 85% budget then blocks), and a recommendation must never
     * point at a model the same screen refuses to install.
     */
    fun bestInstallableModel(totalRamGb: Double, freeRamGb: Double = totalRamGb): ModelEntry {
        val banded = recommendedModel(totalRamGb)
        if (MemoryFitness.check(banded, totalRamGb, freeRamGb).canLoad) return banded
        return ModelCatalog.models
            .filter { MemoryFitness.check(it, totalRamGb, freeRamGb).canLoad }
            .maxByOrNull { it.ramGB }
            ?: ModelCatalog.smallest
    }
}
